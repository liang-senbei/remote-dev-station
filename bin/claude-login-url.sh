#!/bin/bash
# 输出一条【临时公网】noVNC 登录页 URL,给客户在自己浏览器里完成 Claude Code 的无头登录。
# 客户还没进 tailnet 时,novnc.service 只绑 tailscale IP 够不到 → 用 cloudflared 临时开个公网口。
# ⚠️ 这是无密码公网暴露,客户登录完成后务必 `pkill cloudflared` 拆掉。
systemctl is-active --quiet novnc.service || systemctl start novnc.service
TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"; TS_IP="${TS_IP:-127.0.0.1}"
pkill -x cloudflared 2>/dev/null; sleep 1
nohup cloudflared tunnel --url "http://${TS_IP}:6080" >/tmp/cf_login.log 2>&1 &
for i in $(seq 1 20); do
  U=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cf_login.log 2>/dev/null | head -1)
  [ -n "$U" ] && break; sleep 2
done
if [ -n "$U" ]; then
  echo "Claude 登录页(临时公网,登录后请 pkill cloudflared 拆掉): ${U}/vnc.html"
else
  echo "⚠️ 未拿到 cloudflared URL,看 /tmp/cf_login.log;或确认 cloudflared/novnc.service 是否就绪。"
fi
