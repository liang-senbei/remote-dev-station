#!/bin/bash
# 服务器图形桌面(给 AdsPower 等 GUI 用):Xvfb:1 + xfce + x11vnc + noVNC 网页(:6080)。
# 健壮版:全程 wait 在 Xvfb 上——它一死脚本就退出 → systemd 重启整套,
#         修掉旧版"Xvfb 死了、websockify 还在 = 打开 :6080 空壳没桌面"的毛病。
pkill -f "Xvfb :1" 2>/dev/null
pkill -f "x11vnc .*rfbport 5900" 2>/dev/null
pkill -f "websockify .*6080" 2>/dev/null
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null
sleep 1

export DISPLAY=:1
Xvfb :1 -ac -screen 0 1600x900x24 >/var/log/xvfb.log 2>&1 &
XVFB=$!
sleep 3
DISPLAY=:1 xfwm4            >/var/log/xfwm4.log 2>&1 &
DISPLAY=:1 xfdesktop        >/var/log/xfdesktop.log 2>&1 &
DISPLAY=:1 xfce4-panel --disable-wm-check >/var/log/xfce4-panel.log 2>&1 &
sleep 2
# 自动开 Chrome 到 claude.ai/code(网页版 Claude Code:富文本输入+贴图,从服务器干净 IP 登录、不碰 Mac 环境)
DISPLAY=:1 google-chrome --no-sandbox --no-first-run --no-default-browser-check \
  --password-store=basic --disable-session-crashed-bubble --start-maximized \
  --user-data-dir=/root/.chrome-vnc "https://claude.ai/code" >/var/log/chrome-vnc.log 2>&1 &
x11vnc -display :1 -forever -nopw -rfbport 5900 -localhost -xrandr -bg -o /var/log/x11vnc.log 2>/dev/null
sleep 1
# 绑本机自己的 Tailscale IP（自动取、不写死；只在 tailnet 内可达 = 安全边界）
TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"; TS_IP="${TS_IP:-127.0.0.1}"
websockify --web=/usr/share/novnc "${TS_IP}:6080" localhost:5900 >/var/log/websockify.log 2>&1 &

echo "noVNC 桌面已起: http://${TS_IP}:6080/vnc.html  (DISPLAY=:1)"
wait "$XVFB"     # Xvfb 活着就一直 wait;它一死 → 往下 exit → systemd 重启整套
exit 1
