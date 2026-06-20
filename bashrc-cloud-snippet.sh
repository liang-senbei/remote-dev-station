# >>> Moshi-CloudCode setup >>>
export FNM_DIR="$HOME/.fnm"
if [ -f "$FNM_DIR/fnm" ]; then
  export PATH="$FNM_DIR:$PATH"
  eval "$(fnm env --shell bash --use-on-cd)" 2>/dev/null
fi
# 侧边栏/cld 默认模型（Opus 4.8 1M）+ 默认参数（最大推理力度）；想改就改这两行
CLOUD_MODEL="claude-opus-4-8[1m]"
CLOUD_OPTS="--effort max"
cloud() {
  local dir="${1:?用法: cloud <工作目录> [claude 参数...]}"; shift
  cd "$dir" || return 1
  local name="cc-$(basename "$dir")"
  # 多余参数（$*）透传给 claude，如 --continue / --model sonnet 等。注意：仅在「新建」时生效，
  # 若该会话已存在，-A 只是 attach，参数会被忽略。
  tmux new-session -A -s "$name" "cd '$dir' && IS_SANDBOX=1 claude --model '$CLOUD_MODEL' $CLOUD_OPTS --dangerously-skip-permissions $*"
}
# 在同一目录下"新起"一个独立会话：自动取下一个空闲编号 cc-<目录>-2 / -3 ...
cloudnew() {
  local dir="${1:?用法: cloudnew <工作目录> [claude 参数...]}"; shift
  cd "$dir" || return 1
  local base="cc-$(basename "$dir")"
  local dn nameopt=""; read -rp "给这个会话起个名（回车跳过）： " dn
  local name="$base"
  if [ -n "$dn" ]; then
    nameopt="-n '$dn'"                                  # Claude 显示名
    local slug; slug=$(printf '%s' "$dn" | tr ' ./:' '-' | tr -s '-' | sed 's/^-//;s/-$//')
    [ -n "$slug" ] && name="$base-$slug"               # 同时进 tmux 会话名
  fi
  local b="$name" n=2; while tmux has-session -t "$name" 2>/dev/null; do name="$b-$n"; n=$((n+1)); done
  tmux new-session -s "$name" "cd '$dir' && IS_SANDBOX=1 claude --model '$CLOUD_MODEL' $CLOUD_OPTS $nameopt --dangerously-skip-permissions $*"
}
# 新开会话并跑 claude --resume：弹出 Claude 自带的历史对话选择器（可复活已被杀掉但存档还在的对话）
cloud_resume() {
  # 先选项目目录(/opt/workspace 顶层或其子文件夹),再在该目录恢复其历史对话。
  # 原因: claude --resume 只在「当前目录所属项目」里找历史,从 /opt/workspace 恢复子文件夹会话会 No conversation found。
  local dir="$1"
  if [ -z "$dir" ]; then
    command -v fzf >/dev/null || { dir="/opt/workspace"; }
    if [ -z "$dir" ]; then
      local sel
      sel=$( { echo "workspace(顶层)"; find /opt/workspace -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort; } \
        | fzf --prompt="❯ 恢复哪个项目的历史对话  " --height=80% --header-first --header=" 选项目目录 ↵ " ) || return 0
      if [ "$sel" = "workspace(顶层)" ]; then dir="/opt/workspace"; else dir="/opt/workspace/$sel"; fi
    fi
  fi
  cd "$dir" || return 1
  local base="cc-$(basename "$dir")-r" name="$base" n=2
  while tmux has-session -t "$name" 2>/dev/null; do name="$base$n"; n=$((n+1)); done
  exec env -u TMUX tmux new-session -s "$name" "cd '$dir' && IS_SANDBOX=1 claude --model '$CLOUD_MODEL' $CLOUD_OPTS --resume --dangerously-skip-permissions"
}
# 直接进某会话:在跑就 attach;离线就【连名带原对话】--resume 复活(同名同 uuid,绝不新建 -rN)。
# Mac 标签绑定用: cloudconn cloudattach cc-xxx —— 重连永远落回这个会话本身,不再过选择器。
cloudattach() {
  local name="${1:?用法: cloudattach <会话名>}"
  if tmux has-session -t "$name" 2>/dev/null; then exec env -u TMUX tmux attach -t "$name"; fi
  local res dir uuid
  res=$(cc-sessions resolve "$name" 2>/dev/null)
  dir="${res%%$'\t'*}"; uuid="${res##*$'\t'}"
  if [ -n "$dir" ] && [ -n "$uuid" ] && [ "$dir" != "$uuid" ]; then
    exec env -u TMUX tmux new-session -s "$name" \
      "cd '$dir' && IS_SANDBOX=1 claude --model '$CLOUD_MODEL' $CLOUD_OPTS --resume '$uuid' --dangerously-skip-permissions"
  fi
  echo "会话 '$name' 既不在跑、也无可恢复登记(可能已删)。用 cloudgo 选别的或新建。"; return 1
}
cloudforget() { cloud-forget "$@"; }
# fzf 两步：① 选目录(顶层 + 各项目子目录) ② 在该目录下「选已有会话 或 新开一个」
# （一个目录可有多个会话：cc-<名> / cc-<名>-2 / -3 ...）
cloudgo() {
  # 自学习一步到位:此标签(WAVETERM_BLOCKID,由 cloudconn 传入)上次选过哪个会话就记住;
  # 重开/意外退出重进 → 直接进那个会话、不弹菜单。绑的会话真没了,才回落到选择器。
  local bid="${WAVETERM_BLOCKID:-}" bdir="$HOME/.cloud-blockbind"
  [ -d "$bdir" ] && find "$bdir" -type f -mtime +30 -delete 2>/dev/null   # 自动清掉 30 天没用过的死标签绑定
  if [ -n "$bid" ] && [ -s "$bdir/$bid" ]; then
    touch "$bdir/$bid"                                                     # 标记此标签近期在用(防被误清)
    cloudattach "$(cat "$bdir/$bid")"   # 可进则 exec 进入(不返回);会话没了才继续往下弹菜单
  fi
  command -v fzf >/dev/null || { tmux list-sessions 2>/dev/null || echo "(无会话)"; return; }
  local choice key
  choice=$( cloud-sessmenu \
    | fzf --prompt="❯ 会话  " --height=80% --header-first --delimiter=$'\t' --with-nth=2 \
          --header=" ↵ 进入(自动记住此标签)    Ctrl-X 删除(留对话) " \
          --preview 'cloud-sesspreview {1}' \
          --preview-window='right,56%,wrap,border-left' --preview-label=' 预览 ' \
          --bind 'ctrl-x:execute-silent(cloud-forget {1} >/dev/null 2>&1)+reload(cloud-sessmenu)') || return 0
  key="${choice%%$'\t'*}"
  case "$key" in
    "➕") cloudnewat ;;
    "⟳") cloud_resume ;;
    "")  return 0 ;;
    *)   [ -n "$bid" ] && { mkdir -p "$bdir"; printf '%s' "$key" > "$bdir/$bid"; }  # 记住:此标签 ↔ 此会话
         cloudattach "$key" ;;
  esac
}
# 像文件管理器一样逐层进出地浏览/选择/新建目录，再新开会话
cloudnewat() {
  command -v fzf >/dev/null || return 1
  local cur="/opt/workspace" sel
  while true; do
    sel=$( {
        echo "✅ 用当前目录新建会话"
        echo "➕ 在这里新建文件夹"
        [ "$cur" != "/" ] && echo "⬆️ 上一级"
        echo "← 返回会话列表"
        find "$cur" -maxdepth 1 -mindepth 1 -type d -printf '📁 %f\n' 2>/dev/null | sort
      } | fzf --prompt="❯ 目录  " --height=80% --header-first \
              --header=" 📂 $cur " \
              --preview "ls -la --group-directories-first '$cur'/{2..} 2>/dev/null | head -n 50" \
              --preview-window='right,50%,wrap,border-left' --preview-label=' 文件夹内容 ' ) || return 0
    case "$sel" in
      "✅ 用当前目录新建会话") cloudnew "$cur"; return ;;
      "← 返回会话列表")        cloudgo; return ;;
      "⬆️ 上一级")             cur=$(dirname "$cur") ;;
      "➕ 在这里新建文件夹")
        local nn; read -rp "新文件夹名: " nn
        [ -n "$nn" ] && mkdir -p "$cur/$nn" && cur="$cur/$nn" ;;
      "📁 "*) cur="$cur/${sel#📁 }" ;;
      *) return 0 ;;
    esac
  done
}
# <<< Moshi-CloudCode setup <<<
