#!/usr/bin/env bash
# =====================================================================
# hub —— 多 cc(Claude Code)中控 / 互联小工具(基于 tmux)
# ---------------------------------------------------------------------
# 与 ws 配套：ws 管「笔记本↔us4 文件同步」，hub 管「多个 cc 会话的查看 + 互发消息」。
# 受管对象 = tmux 里名字以 cc- 开头的会话(每个工作区一个 cc)。
#
# 用法：
#   hub ls                 列出所有 cc-* 会话：项目路径 + git 远端/状态
#   hub peek <cc> [行数]   看某个 cc 最近 N 行屏幕(默认 40)，知道它在干嘛
#   hub say  <cc> "消息"   给某 cc 发消息(自动包 agent 间通讯 preamble)  ← 默认就用这个
#   hub ask  <cc> "消息"   同 say，但要求对方用 `hub say <我> "..."` 回信
#   hub all  "消息"        广播给除自己外的所有 cc  ← 慎用!需 HUB_ALL_OK=1 才放行
#
# 纪律(防滥用/防误传):
#   · 默认【定向】say/ask 发给某一个 cc;不要图省事用 all 把私事广播给全员。
#   · all 是例外:仅用于真·全员公告(如 FF 收口/全员停手),且必须显式 HUB_ALL_OK=1 才发。
#   · 拿不准对方是否在输入框先 `hub peek`;别习惯性 HUB_FORCE=1 硬发(会绕过就绪护栏=误传根源)。
#
# <cc> 可写全名(cc-frontend)或片段(front / back / docs)，唯一匹配即可。
# 设计：cc 之间的"对话"双向都走 hub say —— 不抓屏解析回复，对方看完直接 hub say 回来。
#       中控(你)在普通 shell 里 hub say/ask 发号、@某个 cc；cc 们之间自己来回。
# =====================================================================

PREFIX="cc-"

_sessions(){ tmux ls -F '#{session_name}' 2>/dev/null | grep "^${PREFIX}" || true; }

# 当前会话名(在某 cc 的 tmux 里跑 = 它；否则空 = 中控/普通 shell)
_self_sess(){ [ -n "${TMUX:-}" ] && tmux display-message -p '#{session_name}' 2>/dev/null || true; }
_self_label(){ local s; s="$(_self_sess)"; [ -n "$s" ] && echo "${s#$PREFIX}" || echo "中控"; }
# 当前会话(发送方)的工作目录:cc 里跑 = 它的项目路径;否则 = 当前 shell 的 PWD(中控)。
# 用于把「来源项目路径」写进 preamble,便于多 agent / 多项目并行协作时定位与回复来源。
_self_path(){ [ -n "${TMUX:-}" ] && tmux display-message -p '#{pane_current_path}' 2>/dev/null || printf '%s' "${PWD:-?}"; }

# 片段 → 唯一 cc-* 会话名(打到 stdout)；失败打错误到 stderr 并返回非 0
_resolve(){
  local q="$1" all want hits n
  all="$(_sessions)"
  # 1) 精确会话名优先:用【真实会话清单】精确比对(grep -xF),不用 tmux has-session
  #    ——tmux has-session -t 本身做前缀模糊匹配(cc-0620 会静默命中 cc-0620-044605),会架空精确判断、酿成误发。
  want="$q"; [[ "$q" == ${PREFIX}* ]] || want="${PREFIX}${q}"
  if printf '%s\n' "$all" | grep -qxF -- "$want"; then echo "$want"; return 0; fi
  # 2) 退化到子串匹配:-F 固定串(避免 label 含正则元字符误伤)
  hits="$(printf '%s\n' "$all" | grep -iF -- "$q" || true)"
  n="$(printf '%s\n' "$hits" | grep -c . || true)"
  if [ "$n" -eq 1 ]; then
    # 模糊唯一命中:警告到 stderr(不污染被捕获的 stdout),让发送方有机会发现是否发错对象
    echo "ℹ️  '$q' 非精确会话名,模糊命中唯一会话 → $hits(确认是你要发的对象;精确请写全 ${PREFIX}<label>)" >&2
    echo "$hits"; return 0
  fi
  if [ "$n" -eq 0 ]; then echo "⛔ 没有匹配 '$q' 的 cc 会话。现有：$(printf '%s\n' "$all" | paste -sd' ' -)" >&2; return 2; fi
  echo "⛔ '$q' 匹配多个：$(printf '%s ' $hits)，写清楚点。" >&2; return 2
}

# 文本与回车之间的停顿(秒)。可用环境变量 HUB_SEND_PAUSE 覆盖(接收方很卡可调大)。
HUB_SEND_PAUSE="${HUB_SEND_PAUSE:-0.3}"

# 安全发送一行(无换行)到某会话当前 pane：先打字面文本(不带回车)→ 停顿 → 再回车提交。
#   为什么要停顿:接收方【空闲】停在提示符上时,若 Enter 紧贴文本零延迟到达,会赶在输入框
#   完整 ingest 文本之前被处理 → 不被识别为提交 → 文本滞留输入框(尤其【末条】消息,后面
#   没有下一轮按键来冲刷缓冲)。中间这点停顿让 Enter 稳定落在「文本已 ingest」之后。
#   接收方【忙】时按键本就被缓冲、在轮次边界连 Enter 一起正常提交,加停顿亦无副作用。
#   注:不做发后 capture-pane 校验 + 补回车——那会与接收方重绘竞态(把「忙/未重绘」误判成
#   「滞留」而误补回车),反而可能给忙碌接收方制造多余空提交;停顿已从根因消除本问题。
# 并发安全:按【接收方】加文件锁,串行化「打文本→停顿→回车」整段——否则多个 agent 同时
# 发给同一接收方时,两条 send-keys -l 会在对方输入框里交错成乱码(加了停顿后交错窗口更大)。
# 锁按接收方分桶,发给不同接收方互不阻塞。无 flock 的环境自动退化为不加锁(行为同单发)。
_send_line(){
  local sess="$1" text="$2"
  {
    flock 9 2>/dev/null || true
    tmux send-keys -t "$sess" -l "$text"
    sleep "$HUB_SEND_PAUSE" 2>/dev/null || sleep 0.3   # 非数字值(typo/locale 0,3)兜底,别退回零延迟竞态
    tmux send-keys -t "$sess" Enter
  } 9>"${TMPDIR:-/tmp}/hub-send-${sess}.lock"
}

# 发送前护栏:粗判目标是否停在【Claude 文本输入框】(底部最后一行 ❯ 提示、且不是编号模态项)。
# 目的:挡住最常见的 footgun——对方在 shell 默认提示符 / cloud 菜单 / 已退出 / pane 不存在时,
# 消息会被当 shell 命令执行(preamble 含 (...)、引号等)。只看可见 pane 末尾几行,避开 scrollback。
# 已知局限(本护栏非万能,别拿它当模态/shell 的可靠防线):
#   · Claude 选择/权限模态把【选中项】也渲染成「❯ 1. Yes」——本护栏靠「❯ 后紧跟编号项就拒」
#     挡住常见的编号弹窗(否则会误把消息打进去、甚至替对方确认高亮项);但【非编号】弹窗仍可能
#     被放行。要安全发,拿不准先 hub peek。
#   · 假设【宿主 shell 提示符不含 ❯】(本机默认 bash 满足)。starship/pure/zsh 等以 ❯ 作提示符的
#     宿主上,接收方掉到 shell 仍会被判就绪——那类宿主请改认输入框边框线,或先 peek。
# HUB_FORCE=1 = 跳过本检查、无条件强发(仅用于护栏误判「未就绪」时);它【不会】让发进
#   shell/模态变安全,只是强发,慎用。
_ready(){
  # HUB_FORCE=1 跳过就绪检查并【大声告警】:硬发是误传根源,不能再静默。仅在确认护栏误判时用。
  [ "${HUB_FORCE:-}" = "1" ] && { echo "⚠️  HUB_FORCE=1 强发,已跳过就绪护栏——若对方不在输入框,内容会落进 shell/弹窗=误传。务必先 hub peek 确认。" >&2; return 0; }
  local prompt
  prompt="$(tmux capture-pane -t "$1" -p 2>/dev/null | tail -6 | grep -F '❯' | tail -1)"
  [ -n "$prompt" ] || return 1                                  # 无 ❯:shell默认提示符/菜单/死pane → 拒
  ! printf '%s' "$prompt" | grep -qE '❯[[:space:]]*[0-9]+[.)]'  # ❯ 指向编号项 = 选择/权限模态 → 拒
}

# 组装 agent 间通讯 preamble(单行)。$1=对方label $2=正文 $3=要回信?(1/0)
# 含「来源项目路径」(@path):多 agent / 多项目并行协作时,接收方据此知道是谁、在哪个项目
# 发来的,以及回复谁(回信仍用标签 → hub say <来源label>)。
_wrap(){
  local tgt="$1" msg="$2" want="$3" me path
  me="$(_self_label)"; path="$(_self_path)"
  msg="$(printf '%s' "$msg" | tr '\n' ' ')"   # 压成单行，避免提前提交
  local p="[HUB·agent间通讯] cc:${me} (@${path}) → 你(cc:${tgt})。${msg} ｜(这是 agent 对接：直接给结论/数据/字段，简洁、机器可读，别写给人看的排版或客套"
  [ "$want" = "1" ] && p="${p}；要回就执行 → hub say ${me} \"<你的答复>\""
  printf '%s)' "$p"
}

cmd="${1:-ls}"; shift 2>/dev/null || true
case "$cmd" in
  ls)
    list="$(_sessions)"
    [ -z "$list" ] && { echo "(没有 ${PREFIX}* 会话)"; exit 0; }
    me="$(_self_label)"
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      path="$(tmux display-message -t "$s" -p '#{pane_current_path}' 2>/dev/null)"
      remote="$(git -C "$path" remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#; s#\.git$##')"
      if git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
        dirty="$(git -C "$path" status --porcelain 2>/dev/null | grep -c . || true)"
        ab="$(git -C "$path" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null | awk '{printf "↓%s ↑%s",$1,$2}')"
        st="${dirty} 处改动 · ${ab:-(无上游)}"
      else
        st="(非 git)"
      fi
      tag=""; [ "${s#$PREFIX}" = "$me" ] && tag="    ← 我在这"
      echo "● ${s}${tag}"
      echo "    git   ${st}"
      echo "    远端  ${remote:--}"
      echo "    路径  ${path}"
    done <<< "$list"
    ;;
  peek)
    t="$(_resolve "${1:?用法: hub peek <cc> [行数]}")" || exit 2
    n="${2:-40}"
    echo "── ${t} · 最近 ${n} 行 ──"
    tmux capture-pane -t "$t" -p -S "-${n}"
    ;;
  say|ask)
    t="$(_resolve "${1:?用法: hub $cmd <cc> \"消息\"}")" || exit 2
    shift
    msg="$*"; [ -z "$msg" ] && { echo "⛔ 消息为空" >&2; exit 2; }
    _ready "$t" || { echo "⛔ ${t} 看着不在 Claude 文本输入框(可能在 shell/菜单/编号弹窗/已退出),没发——否则消息会被当 shell 命令执行。先 hub peek ${t#$PREFIX} 看看;确认就绪可强发:HUB_FORCE=1 hub $cmd …(强发只跳过本检查,不会让发进 shell/模态变安全)" >&2; exit 3; }
    want=0; [ "$cmd" = "ask" ] && want=1
    line="$(_wrap "${t#$PREFIX}" "$msg" "$want")"
    _send_line "$t" "$line"
    echo "✅ 已发给 ${t}："; echo "   $line"
    ;;
  all)
    msg="$*"; [ -z "$msg" ] && { echo "⛔ 消息为空" >&2; exit 2; }
    # 防滥用闸:广播是例外,必须显式 HUB_ALL_OK=1 才放行。日常协作请用定向 hub say <cc>。
    if [ "${HUB_ALL_OK:-}" != "1" ]; then
      echo "⛔ hub all 是【全员广播】,默认禁用以防刷屏/误传。" >&2
      echo "   · 给某个 cc 说话请用定向: hub say <cc> \"...\"" >&2
      echo "   · 确为真·全员公告(FF收口/全员停手等),再显式: HUB_ALL_OK=1 hub all \"...\"" >&2
      exit 4
    fi
    me_sess="$(_self_sess)"; sent=0; skipped=0
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      [ "$s" = "$me_sess" ] && continue
      _ready "$s" || { echo "·  跳过 $s(看着不在 Claude 文本输入框)"; skipped=$((skipped+1)); continue; }
      line="$(_wrap "${s#$PREFIX}" "$msg" 0)"
      _send_line "$s" "$line"; echo "✅ → $s"; sent=$((sent+1))
    done <<< "$(_sessions)"
    echo "(广播完成，共 $sent 个$( [ "$skipped" -gt 0 ] && printf '，跳过 %s 个未就绪' "$skipped" ))"
    ;;
  help|-h|--help)
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    ;;
  *)
    echo "未知命令: $cmd" >&2
    echo "用法: hub {ls|peek|say|ask|all|help}" >&2
    exit 1
    ;;
esac
