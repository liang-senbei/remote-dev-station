# >>> Moshi-CloudCode setup >>>
export FNM_DIR="$HOME/.fnm"
if [ -f "$FNM_DIR/fnm" ]; then
  export PATH="$FNM_DIR:$PATH"
  eval "$(fnm env --shell bash --use-on-cd)" 2>/dev/null
fi
export PATH="$HOME/.local/bin:$PATH"   # 会话辅助脚本(cloud-enter 等)+ native claude 都装在这里
# 会话默认模型 + 参数。账号无该模型就换成可用的(如 claude-sonnet-4-6),否则新建/断电自愈启动即死;
#   改这行还要同步改 /etc/systemd/system/cloud-watchdog.service 的 CLOUD_MODEL(管断电自愈)。cloud-enter 会读这行。
CLOUD_MODEL="claude-opus-4-8[1m]"
CLOUD_OPTS="--effort max"

# 极简 CLI 版:客户 `ssh cloud` 连上得到命令行,像本地一样敲 `claude` 即开始。
# 这里把 `claude` 包成「进/接回那个受管常驻会话」——自动带 IS_SANDBOX(绕 root 沙盒)+ tmux(断线不丢)
# + 断电可 --resume。真要用原生 claude 带参数:`command claude ...`。
claude() { cloud-enter; }

# 【管理员】偶尔要在别的目录另开一个会话时用;客户用不到。
cloud() {
  local dir="${1:?用法: cloud <工作目录> [claude 参数...]}"; shift
  cd "$dir" || return 1
  tmux new-session -A -s "cc-$(basename "$dir")" "cd '$dir' && IS_SANDBOX=1 command claude --model '$CLOUD_MODEL' $CLOUD_OPTS --dangerously-skip-permissions $*"
}

# ssh 登录默认落到工作区根 → 客户可 cd 到不同项目目录、各自敲 claude(每个目录一个对话,像本地)。
if [[ $- == *i* ]] && shopt -q login_shell 2>/dev/null && [ "$PWD" = "$HOME" ]; then cd /opt/workspace 2>/dev/null || true; fi
# <<< Moshi-CloudCode setup <<<
