# >>> Moshi-CloudCode setup >>>
export FNM_DIR="$HOME/.fnm"
if [ -f "$FNM_DIR/fnm" ]; then
  export PATH="$FNM_DIR:$PATH"
  eval "$(fnm env --shell bash --use-on-cd)" 2>/dev/null
fi
# 侧边栏/cld 默认模型（Fable 5 1M，2026-07-02 起从 Opus 4.8 切换）+ 默认参数（最大推理力度）；想改就改这两行
CLOUD_MODEL="claude-fable-5[1m]"
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
  _cloudbind "$name"        # M4:新建的会话也绑到本标签(下次自动进)
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
  local dn; read -rp "给恢复回来的会话起个名(回车=默认 $(basename "$dir")-r): " dn
  local base n=2
  if [ -n "$dn" ]; then
    local slug; slug=$(printf '%s' "$dn" | tr ' ./:' '-' | tr -s '-' | sed 's/^-//;s/-$//')
    base="cc-${slug:-$(basename "$dir")-r}"          # 用你起的名 → cc-<名>(如 cc-hub)
  else
    base="cc-$(basename "$dir")-r"                    # 没起名 → 默认 cc-<目录>-r
  fi
  local name="$base"
  while tmux has-session -t "$name" 2>/dev/null; do name="$base-$n"; n=$((n+1)); done
  _cloudbind "$name"        # M4:恢复出来的会话也绑到本标签(自学习,下次自动进)
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
  if [ -n "$dir" ] && [ -n "$uuid" ] && [ "$dir" != "$uuid" ] && [ -d "$dir" ]; then   # 加 [-d dir]:目录没了不硬 resume(防 M1 失败死循环)
    exec env -u TMUX tmux new-session -s "$name" \
      "cd '$dir' && IS_SANDBOX=1 claude --model '$CLOUD_MODEL' $CLOUD_OPTS --resume '$uuid' --dangerously-skip-permissions"
  fi
  echo "会话 '$name' 既不在跑、也无可恢复登记(可能已删)。用 cloudgo 选别的或新建。"; return 1
}
cloudforget() { cloud-forget "$@"; }
# 记/忘"此标签↔会话"绑定。blockid 走白名单(只允许 uuid 字符),挡 shell 注入 + 路径穿越。
_cloudbind() {
  local b="${WAVETERM_BLOCKID:-}"; case "$b" in ""|*[!0-9a-fA-F-]*) return 0;; esac
  mkdir -p "$HOME/.cloud-blockbind"; printf '%s' "$1" > "$HOME/.cloud-blockbind/$b"
}
cloudunbind() {   # 忘掉本标签的会话绑定 → 下次进此标签重新弹选择器(M3 逃生口)
  local b="${WAVETERM_BLOCKID:-}"; case "$b" in ""|*[!0-9a-fA-F-]*) echo "无可识别的标签 ID";return 1;; esac
  rm -f "$HOME/.cloud-blockbind/$b" && echo "已忘记本标签绑定,下次进此标签会重新让你选。"
}
# 临时会话:开后即用,关标签即销毁(destroy-unattached),不进登记/恢复系统/看板(名字 cc-tmp-* 被 cc-state 跳过);
#           claude 的对话存档(.jsonl)仍保留,日后可 cloud_resume 找回。
cloudtmp() {
  local dir="${1:-/opt/workspace}" name="cc-tmp-$(date +%H%M%S)-$RANDOM"
  exec env -u TMUX tmux new-session -s "$name" \
    "tmux set-option destroy-unattached on 2>/dev/null; cd '$dir' && IS_SANDBOX=1 claude --model '$CLOUD_MODEL' $CLOUD_OPTS --dangerously-skip-permissions"
}
# fzf 两步：① 选目录(顶层 + 各项目子目录) ② 在该目录下「选已有会话 或 新开一个」
# （一个目录可有多个会话：cc-<名> / cc-<名>-2 / -3 ...）
cloudgo() {
  # 自学习一步到位:此标签(WAVETERM_BLOCKID,由 cloudconn 传入)上次选过哪个会话就记住;
  # 重开/意外退出重进 → 直接进那个会话、不弹菜单。绑的会话真没了,才回落到选择器。
  local bid="${WAVETERM_BLOCKID:-}" bdir="$HOME/.cloud-blockbind"
  case "$bid" in *[!0-9a-fA-F-]*) bid= ;; esac                            # 白名单 blockid(M5:防注入/路径穿越)
  [ -n "$bid" ] && [ -f "$bdir/$bid" ] && touch "$bdir/$bid"             # M2:先标记本标签在用(放在清理之前,免长命标签跨30天被误删)
  [ -d "$bdir" ] && find "$bdir" -type f -mtime +30 -delete 2>/dev/null   #     再清 30 天没用过的死绑定
  local bound=""; [ -n "$bid" ] && bound=$(cat "$bdir/$bid" 2>/dev/null)  # L2:单次读,消除 -s/cat 竞态 + 空值守卫
  [ -n "$bound" ] && cloudattach "$bound"   # 可进则 exec 进入(不返回);会话/目录没了才继续往下弹菜单
  command -v fzf >/dev/null || { tmux list-sessions 2>/dev/null || echo "(无会话)"; return; }
  local choice key
  choice=$( cloud-sessmenu \
    | fzf --prompt="❯ 会话  " --height=80% --header-first --delimiter=$'\t' --with-nth=2 \
          --header=" ↵ 进入(记住此标签)    Ctrl-X 分级删除 " \
          --preview 'cloud-sesspreview {1}' \
          --preview-window='right,56%,wrap,border-left' --preview-label=' 预览 ' \
          --bind 'ctrl-x:execute(cloud-delmenu {1})+reload(cloud-sessmenu)') || return 0
  key="${choice%%$'\t'*}"
  case "$key" in
    "➕") cloudnewat ;;
    "⟳") cloud_resume ;;
    "🔓") cloudunbind; sleep 1; cloudgo ;;          # 忘记本标签绑定 → 回菜单重选(改绑逃生口)
    "⏱") cloudtmp ;;                                # 临时会话(并入菜单,省一个侧栏按钮)
    "")  return 0 ;;
    *)   _cloudbind "$key"          # 记住:此标签 ↔ 此会话(统一入口,含白名单)
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
