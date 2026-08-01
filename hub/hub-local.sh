#!/usr/bin/env bash
# =====================================================================
# hub(本地版)—— 让【本机 Claude Code】像服务器上的 agent 一样用 hub。
# ---------------------------------------------------------------------
# 本机没有那些 cc-* tmux 会话(它们都在服务器上),所以本脚本把命令经 ssh 转发过去,
# 并用 HUB_SELF 声明「我是 cc-<HUB_NAME>」—— 这样:
#   · 对方看到的发件人是 cc-local 而不是「中控」;
#   · ask 生成的回信命令是 `hub say local "…"`,回信落进服务器上的 cc-local 会话,
#     也就是本机的信箱(hub-inbox),我再用 `hub inbox` 取走 → 双向闭环。
#
# 用法(与服务器上的 hub 一致,另加 inbox 系列):
#   hub ls                    列出服务器上所有 cc-* (含我自己的信箱 cc-local)
#   hub peek <cc> [n]         看某个 agent 的屏幕
#   hub say  <cc> "消息"      发消息
#   hub ask  <cc> "消息"      发消息并要求回信(回信会进我的信箱)
#   hub inbox                 取未读消息(读完标记已读)   ← 最常用
#   hub inbox --peek          偷看未读(不标已读)
#   hub inbox --all           看全部历史
#   hub inbox --count         只看未读条数
#   hub up                    确保服务器上我的信箱会话活着(没有就拉起)
#
# 配置(二选一,脚本本身保持通用、不写死任何主机):
#   HUB_HOST=<ssh 别名或 user@host>   环境变量;或
#   echo '<ssh 别名>' > ~/.hub-host   写进文件,一次配好
#   HUB_NAME  我在 hub 里的名字(默认 local → 服务器上的会话 cc-local)
# =====================================================================
set -u

HOST="${HUB_HOST:-$(cat "$HOME/.hub-host" 2>/dev/null | head -1 | tr -d '[:space:]')}"
[ -z "$HOST" ] && {
  echo "⛔ 不知道该连哪台:请设 HUB_HOST=<ssh别名|user@host>,或 echo '<别名>' > ~/.hub-host" >&2
  exit 2
}
NAME="${HUB_NAME:-local}"
# 本机真实工作目录报给对方(否则 preamble 里是 ssh 落地的 $PWD,对不上号)
SELF_PATH="${HUB_SELF_PATH:-$PWD}"

# ssh 一次性执行:PATH 补 ~/.local/bin(非交互 ssh 只给极简 PATH,hub 在那儿),
# 并把 HUB_SELF/HUB_SELF_PATH 传过去。参数用 %q 转义,消息里的空格/引号/中文都安全。
_ssh(){
  local cmd=""
  local a
  for a in "$@"; do cmd+="$(printf '%q ' "$a")"; done
  ssh -o BatchMode=yes "$HOST" \
    "export PATH=\"\$HOME/.local/bin:\$PATH\" HUB_SELF=$(printf '%q' "$NAME") HUB_SELF_PATH=$(printf '%q' "$SELF_PATH"); $cmd" \
    2>&1 | grep -v 'remote port forwarding'
}

case "${1:-ls}" in
  inbox)
    shift
    _ssh hub-inbox-read "$NAME" "$@"
    ;;
  up)
    # 幂等:会话在就报活,不在就拉起来
    _ssh bash -lc "tmux has-session -t cc-$NAME 2>/dev/null && echo '✅ 信箱 cc-$NAME 已在跑' || { tmux new-session -d -s cc-$NAME \"hub-inbox $NAME\" && sleep 1 && echo '✅ 已拉起信箱 cc-$NAME'; }"
    ;;
  help|-h|--help)
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    ;;
  *)
    _ssh hub "$@"
    ;;
esac
