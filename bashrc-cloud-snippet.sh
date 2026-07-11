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

# 极简 CLI 版:客户端 `ssh cloud` 经 RemoteCommand 直接跑 cloud-enter 进那个常驻会话(无 cloudgo 选单)。
# 下面只是【管理员】偶尔要在别的目录另开 claude 时用;客户用不到。
cloud() {
  local dir="${1:?用法: cloud <工作目录> [claude 参数...]}"; shift
  cd "$dir" || return 1
  tmux new-session -A -s "cc-$(basename "$dir")" "cd '$dir' && IS_SANDBOX=1 claude --model '$CLOUD_MODEL' $CLOUD_OPTS --dangerously-skip-permissions $*"
}
# <<< Moshi-CloudCode setup <<<
