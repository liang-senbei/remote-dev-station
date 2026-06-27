#!/bin/bash
# 中控 / 远程开发系统 基建体检 —— 查 cloud-setup 那套常驻服务/定时器是否都在 + moshi socket 功能探活。
# 架构/详情见 cloud-setup/README.md §7、§10。多数恢复 = systemctl restart <unit>(下面每条 ❌ 带提示)。
bad=0
chk(){  # $1=unit  $2=说明  $3=恢复提示
  if systemctl is-active --quiet "$1"; then echo "  ✓ $1 ($2)"
  else echo "  ❌ $1 ($2) —— 恢复: $3"; bad=1; fi
}
echo "-- systemd 常驻(active?) --"
chk moshi-hook.service           "hub发送+手机审批 daemon"  "systemctl restart moshi-hook.service"
chk moshi-hook-healthcheck.timer "daemon卡死自愈兜底"       "systemctl enable --now moshi-hook-healthcheck.timer"
chk cloud-watchdog.timer         "会话断电自愈(每15s)"     "systemctl enable --now cloud-watchdog.timer"
chk cloud-sessions.service       "开机拉起 watchdog"        "systemctl restart cloud-sessions.service"
chk tailscaled.service           "中美加密内网(命脉)"      "tailscale up"
chk fail2ban.service             "SSH 防爆破"               "systemctl restart fail2ban"
chk novnc.service                "服务器 GUI 桌面 :6080"    "systemctl restart novnc.service"
chk cloud-dashboards.service     "项目看板 :8088"           "systemctl restart cloud-dashboards.service"
chk cloudflared.service          "对外域名隧道"            "systemctl restart cloudflared.service"
echo "-- 功能探活 --"
if timeout 12 /root/.local/bin/moshi-hook status >/dev/null 2>&1; then
  echo "  ✓ moshi-hook daemon socket 响应"
else
  echo "  ❌ moshi-hook socket 无响应(进程在也可能卡死)—— systemctl restart moshi-hook.service"; bad=1
fi
[ "$bad" = 0 ] && echo "== 中控基建全绿 ==" || echo "== 有 ❌,按上面提示恢复 =="
exit $bad
