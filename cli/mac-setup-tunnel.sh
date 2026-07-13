#!/bin/bash
# ============================================================
# 一键部署 · Mac 客户机反向隧道（remote-dev-station · CLI 版）
# 用法（在客户机上跑）:
#   bash mac-setup-tunnel.sh <服务器IP> ["<服务器公钥>"]
# 跑完:① 屏幕打印【本机公钥】——发给部署方加到服务器 authorized_keys
#       ② 反向隧道已设开机自启;服务器加好公钥后自动接通
# ============================================================
set -e
SERVER="$1"; SRVPUB="${2:-}"; PORT="${PORT:-2222}"
[ -z "$SERVER" ] && { echo "用法: bash mac-setup-tunnel.sh <服务器IP> [\"<服务器公钥>\"]"; exit 1; }
case "$SERVER" in *@*) ;; *) SERVER="root@$SERVER";; esac
KEY="$HOME/.ssh/id_ed25519"

echo "== [1/5] 开启远程登录（sshd） =="
sudo systemsetup -setremotelogin on 2>/dev/null \
  && echo "  -> 远程登录已开" \
  || echo "  ! 自动开启失败:请到 系统设置→通用→共享→远程登录 手动打开（可能要先给终端『完全磁盘访问权限』）"

echo "== [2/5] 生成本机 SSH 密钥（已有则复用） =="
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
[ -f "$KEY" ] || ssh-keygen -t ed25519 -f "$KEY" -N "" -C "client-$(hostname -s)"

echo "== [+] 写 ssh 'cloud' 别名（以后 ssh cloud 直接连服务器 → 敲 claude） =="
CFG="$HOME/.ssh/config"; touch "$CFG"; chmod 600 "$CFG"
HOSTONLY="${SERVER##*@}"; USERONLY="${SERVER%@*}"; [ "$USERONLY" = "$SERVER" ] && USERONLY=root
if grep -qE '^[[:space:]]*Host[[:space:]]+cloud[[:space:]]*$' "$CFG"; then
  echo "  -> 已有 cloud 别名，不动"
else
  printf '\nHost cloud\n    HostName %s\n    User %s\n    IdentityFile %s\n    IdentitiesOnly yes\n    ServerAliveInterval 30\n' "$HOSTONLY" "$USERONLY" "$KEY" >> "$CFG"
  echo "  -> 已写 cloud 别名 → $HOSTONLY（ssh cloud 连上 → 敲 claude）"
fi

echo "== [3/5] 授权服务器回连（服务器公钥 -> authorized_keys） =="
if [ -n "$SRVPUB" ]; then
  touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
  grep -qxF "$SRVPUB" "$HOME/.ssh/authorized_keys" || echo "$SRVPUB" >> "$HOME/.ssh/authorized_keys"
  echo "  -> 已授权服务器公钥（服务器可反向读你文件）"
else
  echo "  ! 没传服务器公钥:服务器暂时无法反向读你文件。拿到后重跑带上即可。"
fi

echo "== [4/5] 反向隧道设为开机自启（launchd + 断线重连） =="
AUTOSSH="$(command -v autossh || true)"
PLIST="$HOME/Library/LaunchAgents/com.remotedev.tunnel.plist"
mkdir -p "$HOME/Library/LaunchAgents"
if [ -n "$AUTOSSH" ]; then
  PROG="$AUTOSSH"; set -- -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -i "$KEY" -R "${PORT}:localhost:22" "$SERVER"
else
  echo "  ! 未装 autossh（brew install autossh 更稳）;先用纯 ssh + KeepAlive 兜底"
  PROG="/usr/bin/ssh"; set -- -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -i "$KEY" -R "${PORT}:localhost:22" "$SERVER"
fi
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  echo '  <key>Label</key><string>com.remotedev.tunnel</string>'
  echo '  <key>ProgramArguments</key><array>'
  echo "    <string>${PROG}</string>"
  for a in "$@"; do echo "    <string>${a}</string>"; done
  echo '  </array>'
  echo '  <key>RunAtLoad</key><true/>'
  echo '  <key>KeepAlive</key><true/>'
  echo '</dict></plist>'
} > "$PLIST"
UID_="$(id -u)"
launchctl bootout "gui/$UID_/com.remotedev.tunnel" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
launchctl enable "gui/$UID_/com.remotedev.tunnel" 2>/dev/null || true
launchctl kickstart "gui/$UID_/com.remotedev.tunnel" 2>/dev/null || true
echo "  -> 隧道服务已加载（com.remotedev.tunnel;开机自启 + 断线重连）"

echo "== [5/5] 完成。把下面这行【本机公钥】发给部署方（加到服务器 authorized_keys）: =="
cat "$KEY.pub"
cp "$KEY.pub" "$HOME/Desktop/client-pubkey.txt" 2>/dev/null || true
echo "（也已存到桌面: ~/Desktop/client-pubkey.txt）"
