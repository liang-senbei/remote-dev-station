#!/usr/bin/env bash
# =====================================================================
# hub —— 多 cc(Claude Code)操作台 / 互联小工具(基于 tmux)
# ---------------------------------------------------------------------
# 与 ws 配套：ws 管「笔记本↔us4 文件同步」，hub 管「多个 cc 会话的查看 + 互发消息」。
# 受管对象 = tmux 里名字以 cc- 开头的会话(每个工作区一个 cc)。
#
# 用法：
#   hub ls                 列出所有 cc-* 会话：项目路径 + git 远端/状态
#   hub peek <cc> [行数]   看某个 cc 最近 N 行屏幕(默认 40)，知道它在干嘛
#   hub say  <cc> "消息"   给某 cc 发消息(自动包 agent 间通讯 preamble)
#   hub ask  <cc> "消息"   同 say，但要求对方用 `hub say <我> "..."` 回信
#   hub all  "消息"        广播给除自己外的所有 cc
#
# <cc> 可写全名(cc-frontend)或片段(front / back / docs)，唯一匹配即可。
# 设计：cc 之间的"对话"双向都走 hub say —— 不抓屏解析回复，对方看完直接 hub say 回来。
#       操作台(你)在普通 shell 里 hub say/ask 发号、@某个 cc；cc 们之间自己来回。
# =====================================================================

PREFIX="cc-"

_sessions(){ tmux ls -F '#{session_name}' 2>/dev/null | grep "^${PREFIX}" || true; }

# 当前会话名(在某 cc 的 tmux 里跑 = 它；否则空 = 操作台/普通 shell)
_self_sess(){ [ -n "${TMUX:-}" ] && tmux display-message -p '#{session_name}' 2>/dev/null || true; }
_self_label(){ local s; s="$(_self_sess)"; [ -n "$s" ] && echo "${s#$PREFIX}" || echo "操作台"; }

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

# 安全发送一行(无换行)到某会话当前 pane：先打字面文本，再单独回车提交
_send_line(){
  local sess="$1" text="$2"
  tmux send-keys -t "$sess" -l "$text"
  tmux send-keys -t "$sess" Enter
}

# 组装 agent 间通讯 preamble(单行)。$1=对方label $2=正文 $3=要回信?(1/0)
_wrap(){
  local tgt="$1" msg="$2" want="$3" me; me="$(_self_label)"
  msg="$(printf '%s' "$msg" | tr '\n' ' ')"   # 压成单行，避免提前提交
  local p="[HUB·agent间通讯] cc:${me} → 你(cc:${tgt})。${msg} ｜(这是 agent 对接：直接给结论/数据/字段，简洁、机器可读，别写给人看的排版或客套"
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
    want=0; [ "$cmd" = "ask" ] && want=1
    line="$(_wrap "${t#$PREFIX}" "$msg" "$want")"
    _send_line "$t" "$line"
    echo "✅ 已发给 ${t}："; echo "   $line"
    ;;
  all)
    msg="$*"; [ -z "$msg" ] && { echo "⛔ 消息为空" >&2; exit 2; }
    me_sess="$(_self_sess)"; sent=0
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      [ "$s" = "$me_sess" ] && continue
      line="$(_wrap "${s#$PREFIX}" "$msg" 0)"
      _send_line "$s" "$line"; echo "✅ → $s"; sent=$((sent+1))
    done <<< "$(_sessions)"
    echo "(广播完成，共 $sent 个)"
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
