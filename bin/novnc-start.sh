#!/bin/bash
export DISPLAY=:1
Xvfb :1 -ac -screen 0 1280x720x24 >/var/log/xvfb.log 2>&1 &
sleep 3
DISPLAY=:1 xfconfd &
sleep 1
DISPLAY=:1 xfwm4 >/var/log/xfwm4.log 2>&1 &
sleep 1
DISPLAY=:1 xfdesktop >/var/log/xfdesktop.log 2>&1 &
sleep 1
DISPLAY=:1 xfce4-panel --disable-wm-check >/var/log/xfce4-panel.log 2>&1 &
sleep 2
x11vnc -display :1 -forever -nopw -rfbport 5900 -localhost -bg -o /var/log/x11vnc.log 2>/dev/null
sleep 2
exec websockify --web=/usr/share/novnc 100.109.254.125:6080 localhost:5900
