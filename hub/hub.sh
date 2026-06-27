#!/usr/bin/env bash
# =====================================================================
# hub —— 多 cc(Claude Code)中控 / 互联小工具(基于 tmux)
# ---------------------------------------------------------------------
# 与 ws 配套：ws 管「笔记本↔us4 文件同步」，hub 管「多个 cc 会话的查看 + 互发消息」。
# 受管对象 = tmux 里名字以 cc- 开头的会话(每个工作区一个 cc)。
#
# 用法：
#   hub ls                 列出所有 cc-* 会话：项目路径 + git 远端/状态 + 留言箱待发数
#   hub peek <cc> [行数]   看某个 cc 最近 N 行屏幕(默认 40)，知道它在干嘛
#   hub say  <cc> "消息"   给某 cc 发消息(自动包 agent 间通讯 preamble)
#   hub ask  <cc> "消息"   同 say，但要求对方用 `hub say <我> "..."` 回信
#   hub all  "消息"        广播给除自己外的所有 cc
#   hub flush [<cc>]       手动把留言箱里待发的消息投出去(就绪才发;省略=所有会话)
#   hub inbox [<cc>] [clear]  查看(或清空)某会话的留言箱
#
# <cc> 可写全名(cc-frontend)或片段(front / back / docs)，唯一匹配即可。
#
# 投递 = tmux send-keys 把文本打进对方的 Claude 输入框。发送前会判断对方是否
# 「停在空的 ❯ 输入框」(含 agent-teams 子 agent 名册空闲态、忙/思考中但输入框为空——
# 都能安全投递,忙时会被 type-ahead 排队、那一轮结束后处理)。若对方在 shell/已退出/
# 权限模态/输入框有草稿/正在查看某子 agent —— 不硬发(否则消息会被当 shell 命令、或灌进
# 模态/子 agent),而是【存入留言箱】并起一个后台看守,它一回到空输入框就自动投递。
#   · 留言箱目录:~/.hub-inbox/<会话>.tsv(每行一条:epoch <tab> 来源 <tab> 整行消息)。
#   · 看守:`hub _watch <会话>`,setsid 脱离终端、每会话单例(flock),最长盯 30 分钟。
#   · HUB_FORCE=1 跳过就绪判断、无条件直发(仅用于检测器误判时;它【不会】让发进
#     shell/模态变安全,只是强发,慎用)。
# 设计：cc 之间的"对话"双向都走 hub say —— 不抓屏解析回复，对方看完直接 hub say 回来。
# =====================================================================

PREFIX="cc-"

_sessions(){ tmux ls -F '#{session_name}' 2>/dev/null | grep "^${PREFIX}" || true; }

# 当前会话名(在某 cc 的 tmux 里跑 = 它；否则空 = 中控/普通 shell)
_self_sess(){ [ -n "${TMUX:-}" ] && tmux display-message -p '#{session_name}' 2>/dev/null || true; }
_self_label(){ local s; s="$(_self_sess)"; [ -n "$s" ] && echo "${s#$PREFIX}" || echo "中控"; }
# 当前会话(发送方)的工作目录:cc 里跑 = 它的项目路径;否则 = 当前 shell 的 PWD(中控)。
# 用于把「来源项目路径」写进 preamble,便于多 agent / 多项目并行协作时定位与回复来源。
_self_path(){ [ -n "${TMUX:-}" ] && tmux display-message -p '#{pane_current_path}' 2>/dev/null || printf '%s' "${PWD:-?}"; }

# 各会话「一句话自报」+「看板声明」的存储(各写各的文件,无并发冲突)。
SUMDIR="$HOME/.cloud-summaries"
_summary(){ cat "$SUMDIR/$1.txt" 2>/dev/null; }
_dash(){ cat "$SUMDIR/$1.dash" 2>/dev/null; }

# 留言箱(投不出时落盘,就绪后自动投递)。
INBOX="${HUB_INBOX_DIR:-$HOME/.hub-inbox}"

# 片段 → 唯一 cc-* 会话名(打到 stdout)；失败打错误到 stderr 并返回非 0
_resolve(){
  local q="$1" hits n
  if [[ "$q" == ${PREFIX}* ]] && tmux has-session -t "$q" 2>/dev/null; then echo "$q"; return 0; fi
  if tmux has-session -t "${PREFIX}${q}" 2>/dev/null; then echo "${PREFIX}${q}"; return 0; fi
  hits="$(_sessions | grep -i -- "$q" || true)"
  n="$(printf '%s\n' "$hits" | grep -c . || true)"
  if [ "$n" -eq 1 ]; then echo "$hits"; return 0; fi
  if [ "$n" -eq 0 ]; then echo "⛔ 没有匹配 '$q' 的 cc 会话。现有：$(_sessions | paste -sd' ' -)" >&2; return 2; fi
  echo "⛔ '$q' 匹配多个：$(printf '%s ' $hits)，写清楚点。" >&2; return 2
}

# ---------------------------------------------------------------------
# 就绪判断:抓对方屏幕,判断当前可投递性。打印状态词到 stdout:
#   ready  —— 停在 Claude 空输入框(含 agent-teams 名册空闲态 / 忙但输入框为空),可投递
#   shell  —— 不是 Claude TUI(普通 shell / 已退出 / 死 pane)
#   viewing—— 正在查看某子 agent 的 transcript(焦点在子 agent 面板),硬发会误操作
#   modal  —— 权限/选择模态(❯ 1. … / ❯ Yes/No / "Do you want to proceed?")
#   draft  —— 输入框里已有草稿文本(别覆盖)
#   nobox  —— 有 Claude chrome 但定位不到输入框(异常态),保守不投递
# 为何用 python3:要按 Unicode 精确处理 ❯(U+276F)、⏵⏵(U+23F5)、NBSP(U+00A0)等字形,
#   bash/grep 处理多字节空白极易出错。python3 在本环境必有(hub-gate.py 同样依赖)。
# 关键依据(经 claude-code-guide 反编译 Claude Code 2.1.179 binary + 官方 doc 三方核实):
#   · agent-teams 开启时,子 agent 名册渲染在状态行【下方】,把 ❯ 输入框顶到状态行上方;
#     默认键盘焦点仍在 ❯ 输入框(按 ← "for agents" 才进名册)→ 名册空闲态可安全投递。
#   · 忙(转圈)时 type-ahead 会被安全排队,那一轮结束后提交 → 输入框为空即可投递。
#   · 模态选中项渲染成「❯ 1. Yes」;查看子 agent 时底部出现「return to team lead」。
HUB_PYCLASSIFY='
import sys, re
data = sys.stdin.read()
lines = data.split("\n")
tail = lines[-8:] if len(lines) >= 8 else lines
# 正在查看某子 agent(焦点不在主输入框)—— 仅在底部 footer 区精确匹配,避免正文误命中
if any("return to team lead" in ln for ln in tail):
    print("viewing"); sys.exit(0)
# 定位 Claude chrome:模式行 ⏵⏵(U+23F5)最可靠;退而求其次 (1M context) / ctx N%
# 取【最后一次】出现 —— 真正的底部 chrome 总在正文之下,从而盖过正文里的偶然同词
chrome = -1
for i, ln in enumerate(lines):
    if "⏵" in ln or "(1M context)" in ln:
        chrome = i
if chrome < 0:
    for i, ln in enumerate(lines):
        if re.search(r"ctx \d", ln):
            chrome = i
if chrome < 0:
    print("shell"); sys.exit(0)
# 定位输入框:chrome 之上、最靠近的 ❯ 行(名册在 chrome 之下,无 ❯;历史 ❯ 在更上方)
box = -1
for i in range(chrome):
    if lines[i].lstrip().startswith("❯"):
        box = i
if box < 0:
    print("nobox"); sys.exit(0)
content = lines[box].split("❯", 1)[1]
stripped = content.replace(" ", "").strip()   # 去普通空白 + NBSP
if stripped == "":
    print("ready"); sys.exit(0)
if re.match(r"\s*\d+[.)]", content) or re.match(r"\s*(Yes|No)\b", content) or ("Do you want to proceed" in data):
    print("modal"); sys.exit(0)
print("draft"); sys.exit(0)
'

# 抓屏 → 分类(无 python3 时退化为宽松判断:扫全屏找空 ❯ 行)
_classify(){
  local cap
  cap="$(tmux capture-pane -t "$1" -p 2>/dev/null)" || { echo "shell"; return 0; }
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$cap" | python3 -c "$HUB_PYCLASSIFY"
  else
    # 兜底:有 ⏵⏵ chrome 且某行是空 ❯ 框 → ready;否则 shell(粗判,够用)
    if printf '%s' "$cap" | grep -qF '⏵⏵' && printf '%s' "$cap" | grep -qP '❯[\s\xa0]*$'; then
      echo "ready"
    else
      echo "shell"
    fi
  fi
}

# 状态词 → 中文(给用户看的提示)
_state_zh(){ case "$1" in
  ready)   echo "空闲输入框";;
  shell)   echo "非Claude界面/shell/已退出";;
  viewing) echo "正在查看子agent";;
  modal)   echo "权限/选择模态";;
  draft)   echo "输入框有草稿";;
  nobox)   echo "定位不到输入框";;
  *)       echo "$1";;
esac; }

# 是否就绪(含 HUB_FORCE 强发)
_ready(){ [ "${HUB_FORCE:-}" = "1" ] && return 0; [ "$(_classify "$1")" = "ready" ]; }

# 文本与回车之间的停顿(秒)。可用环境变量 HUB_SEND_PAUSE 覆盖(接收方很卡可调大)。
HUB_SEND_PAUSE="${HUB_SEND_PAUSE:-0.3}"

# 安全发送一行(无换行)到某会话当前 pane：先打字面文本(不带回车)→ 停顿 → 再回车提交。
#   为什么要停顿:接收方【空闲】停在提示符上时,若 Enter 紧贴文本零延迟到达,会赶在输入框
#   完整 ingest 文本之前被处理 → 不被识别为提交 → 文本滞留输入框(尤其【末条】消息,后面
#   没有下一轮按键来冲刷缓冲)。中间这点停顿让 Enter 稳定落在「文本已 ingest」之后。
# 并发安全:按【接收方】加文件锁,串行化「打文本→停顿→回车」整段——否则多个 agent 同时
# 发给同一接收方时,两条 send-keys -l 会在对方输入框里交错成乱码。锁按接收方分桶,发给不同
# 接收方互不阻塞。无 flock 的环境自动退化为不加锁(行为同单发)。
_send_line(){
  local sess="$1" text="$2"
  {
    flock 9 2>/dev/null || true
    tmux send-keys -t "$sess" -l "$text"
    sleep "$HUB_SEND_PAUSE" 2>/dev/null || sleep 0.3   # 非数字值(typo/locale 0,3)兜底,别退回零延迟竞态
    tmux send-keys -t "$sess" Enter
  } 9>"${TMPDIR:-/tmp}/hub-send-${sess}.lock"
}

# 组装 agent 间通讯 preamble(单行;字段化「类型/正文/回执/规矩」+ 禁客套硬规矩)。
# 单行是硬约束:tmux 里多行会提前提交,故用 ｜ 分隔而非换行。$1=对方label $2=正文 $3=要回信?(1/0)
_wrap(){
  local tgt="$1" msg="$2" want="$3" me path kind reply
  me="$(_self_label)"; path="$(_self_path)"
  msg="$(printf '%s' "$msg" | tr '\n\t' '  ')"   # 压成单行(去换行+Tab),避免提前提交/破坏 TSV
  if [ "$want" = "1" ]; then
    kind="需回复"; reply="必回 → hub say ${me} \"<结论/数据>\""
  else
    kind="知会"; reply="无需回复;有需求才 hub say ${me} \"…\""
  fi
  printf '[HUB·机器对接] cc:%s(@%s) → cc:%s ｜类型: %s ｜正文: %s ｜回执: %s ｜规矩: agent↔agent 机器对接——只给结论/数据/字段/决策,禁开场白·问候·致谢·客套·复述原话·给人看排版,能一句别两句' \
    "$me" "$path" "$tgt" "$kind" "$msg" "$reply"
}

# ---------------------------------------------------------------------
# 留言箱:存 / 计数 / 投递 / 看守
_spool(){  # $1=会话  $2=整行消息(已 wrap)  $3=来源label
  mkdir -p "$INBOX"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$3" "$(printf '%s' "$2" | tr '\t\n' '  ')" >> "$INBOX/$1.tsv"
}
_inbox_count(){ [ -f "$INBOX/$1.tsv" ] && grep -c . "$INBOX/$1.tsv" 2>/dev/null || echo 0; }

# 投递某会话留言箱里所有待发(逐条判断就绪,一旦不就绪即停、保留剩余)。打印投出条数。
# 并发安全:全程持 flush 锁(单例);实际按键由 _send_line 的 send 锁再次串行化。
_flush(){
  local sess="$1" f="$INBOX/$1.tsv"
  [ -s "$f" ] || { echo 0; return 0; }
  exec 8>"${TMPDIR:-/tmp}/hub-flush-${sess}.lock"
  flock -n 8 || { echo 0; return 0; }     # 已有 flush 在跑 → 让它去做
  local rows=(); mapfile -t rows < "$f"
  local i n=${#rows[@]} delivered=0 line
  for ((i=0; i<n; i++)); do
    [ -z "${rows[i]}" ] && continue
    line="${rows[i]#*$'\t'}"; line="${line#*$'\t'}"   # 取第 3 列(整行消息;它本身已无 tab)
    [ -z "$line" ] && { rows[i]=""; continue; }
    [ "$(_classify "$sess")" = "ready" ] || break      # 不再就绪:停,保留本条及之后
    _send_line "$sess" "$line"
    delivered=$((delivered+1)); rows[i]=""
    sleep "$HUB_SEND_PAUSE" 2>/dev/null || sleep 0.3   # 条间停顿,避免连发交错
  done
  : > "$f"                                              # 回写未投递的(从 break 处起)
  for ((; i<n; i++)); do [ -n "${rows[i]}" ] && printf '%s\n' "${rows[i]}" >> "$f"; done
  [ -s "$f" ] || rm -f "$f"
  echo "$delivered"
}

# 起一个后台看守(脱离终端、每会话单例),它一就绪就 flush;留言清空或超时即退。
_ensure_watcher(){
  local sess="$1"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$0" _watch "$sess" >/dev/null 2>&1 </dev/null &
  else
    nohup bash "$0" _watch "$sess" >/dev/null 2>&1 </dev/null &
  fi
  disown 2>/dev/null || true
}

cmd="${1:-ls}"; shift 2>/dev/null || true

# 允许被测试 source(只加载函数/变量,不分发命令):HUB_LIB=1 source hub.sh
if [ -n "${HUB_LIB:-}" ]; then return 0 2>/dev/null || exit 0; fi

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
      sum="$(_summary "$s")"; [ -n "$sum" ] && echo "    在做  ${sum}"
      dsh="$(_dash "$s")";    [ -n "$dsh" ] && echo "    看板  ${dsh}"
      ic="$(_inbox_count "$s")"; [ "${ic:-0}" -gt 0 ] && echo "    留言  📭 ${ic} 条待发(就绪自动投递;hub flush ${s#$PREFIX} 催)"
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
    want=0; [ "$cmd" = "ask" ] && want=1
    line="$(_wrap "${t#$PREFIX}" "$msg" "$want")"
    # 纯直发(2026-06-28 用户拍板):不判定就绪、不 spool,直接 send-keys 投进对方输入框。
    # 旧的"投不出就存留言箱+30min看守"会在目标长期不就绪时永久卡死丢消息,故废弃。
    _send_line "$t" "$line"
    echo "✅ 已直发给 ${t}："; echo "   $line"
    ;;
  all)
    msg="$*"; [ -z "$msg" ] && { echo "⛔ 消息为空" >&2; exit 2; }
    me_sess="$(_self_sess)"; sent=0
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      [ "$s" = "$me_sess" ] && continue
      line="$(_wrap "${s#$PREFIX}" "$msg" 0)"
      _send_line "$s" "$line"; echo "✅ → $s"; sent=$((sent+1))   # 纯直发,不判定/不 spool
    done <<< "$(_sessions)"
    echo "(广播完成:直发 $sent 个)"
    ;;
  flush)
    if [ -n "${1:-}" ]; then
      t="$(_resolve "$1")" || exit 2
      d="$(_flush "$t")"
      echo "✅ ${t}: 投递 ${d} 条$( [ -s "$INBOX/$t.tsv" ] && printf '，仍余 %s 条(未就绪)' "$(_inbox_count "$t")" )"
    else
      any=0
      for f in "$INBOX"/*.tsv; do
        [ -e "$f" ] || continue
        s="$(basename "$f" .tsv)"; tmux has-session -t "$s" 2>/dev/null || continue
        d="$(_flush "$s")"; [ "${d:-0}" -gt 0 ] && { echo "✅ ${s}: 投递 ${d} 条"; any=1; }
      done
      [ "$any" = 0 ] && echo "(没有可投递的留言)"
    fi
    ;;
  inbox)
    sub="${1:-}"
    if [ -n "$sub" ] && [ "$sub" != "all" ]; then
      t="$(_resolve "$sub")" || exit 2
      if [ "${2:-}" = "clear" ]; then rm -f "$INBOX/$t.tsv"; echo "✅ 已清空 ${t} 留言箱"; exit 0; fi
      f="$INBOX/$t.tsv"; [ -s "$f" ] || { echo "(${t} 留言箱空)"; exit 0; }
      echo "── ${t} 留言箱（待发 $(_inbox_count "$t") 条）──"
      while IFS=$'\t' read -r epoch from line; do
        [ -z "$line" ] && continue
        when="$(date -d "@$epoch" '+%m-%d %H:%M' 2>/dev/null || echo "$epoch")"
        echo "  [$when] 来自 ${from}: $(printf '%s' "$line" | cut -c1-90)"
      done < "$f"
    else
      any=0
      for f in "$INBOX"/*.tsv; do
        [ -e "$f" ] || continue; [ -s "$f" ] || continue
        s="$(basename "$f" .tsv)"; echo "📭 ${s}: $(grep -c . "$f") 条待发"; any=1
      done
      [ "$any" = 0 ] && echo "(所有留言箱都空)"
    fi
    ;;
  _watch)   # 隐藏:后台看守,每会话单例(flock),就绪即 flush;留言清空或超时退出
    sess="${1:-}"; [ -n "$sess" ] || exit 0
    exec 7>"${TMPDIR:-/tmp}/hub-watch-${sess}.lock"
    flock -n 7 || exit 0                                  # 已有看守在盯 → 退
    end=$(( $(date +%s) + ${HUB_WATCH_MAX:-1800} ))       # 最长盯 30 分钟
    while [ -s "$INBOX/$sess.tsv" ]; do
      [ "$(date +%s)" -ge "$end" ] && break
      tmux has-session -t "$sess" 2>/dev/null || break    # 会话没了 → 退(留言留存)
      [ "$(_classify "$sess")" = "ready" ] && _flush "$sess" >/dev/null
      sleep "${HUB_WATCH_POLL:-3}"
    done
    exit 0
    ;;
  iam)
    me="$(_self_sess)"; [ -n "$me" ] || { echo "⛔ 不在某个 cc 会话里,无法确定是谁。请在某个 cc 标签里跑 hub iam。" >&2; exit 2; }
    txt="$*"
    if [ -z "$txt" ]; then echo "「${me#$PREFIX}」当前一句话: $(_summary "$me" || echo '(空)')"; exit 0; fi
    mkdir -p "$SUMDIR"; printf '%s' "$(printf '%s' "$txt" | tr '\n' ' ')" > "$SUMDIR/${me}.txt"
    "$0" overview >/dev/null 2>&1
    echo "✅ 已更新「${me#$PREFIX}」一句话: $txt"
    ;;
  dash)
    me="$(_self_sess)"; [ -n "$me" ] || { echo "⛔ 不在 cc 会话里。" >&2; exit 2; }
    url="${1:-}"; mode="${2:-manual}"; mkdir -p "$SUMDIR"
    if [ -z "$url" ] || [ "$url" = "none" ]; then
      rm -f "$SUMDIR/${me}.dash"; echo "✅ 「${me#$PREFIX}」声明:无看板"
    else
      printf '%s [%s]' "$url" "$mode" > "$SUMDIR/${me}.dash"; echo "✅ 「${me#$PREFIX}」看板: $url [$mode]"
    fi
    "$0" overview >/dev/null 2>&1
    ;;
  overview)
    out="${HUB_OVERVIEW:-/opt/workspace/会话总览.md}"
    {
      echo "# 会话总览(各 cc 自报 · hub 自动生成,别手编)"
      echo
      echo "> 各会话用 \`hub iam \"一句话\"\` 报告在干嘛;有看板的用 \`hub dash <url> [auto|manual]\` 声明。其它会话/中控靠这张表知道彼此在做什么。"
      echo
      echo "| 会话 | 在做什么 | 看板 |"
      echo "|---|---|---|"
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        case "$s" in ${PREFIX}tmp-*) continue ;; esac   # 临时会话不进总览
        sum="$(_summary "$s")"; dsh="$(_dash "$s")"
        echo "| ${s#$PREFIX} | ${sum:-—} | ${dsh:-—} |"
      done <<< "$(_sessions)"
    } > "$out"
    echo "✅ 已生成 $out"
    ;;
  help|-h|--help)
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    ;;
  *)
    echo "未知命令: $cmd" >&2
    echo "用法: hub {ls|peek|iam|dash|overview|say|ask|all|flush|inbox|help}" >&2
    exit 1
    ;;
esac
