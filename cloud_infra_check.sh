#!/bin/bash
# 中控 / 远程开发系统 基建体检 —— 查 cloud-setup 那套常驻服务/定时器。
# 架构/详情见 cloud-setup/README.md §7、§10。多数恢复 = systemctl restart <unit>。
# 核心层(chk)失败 = 非绿;可选层(chkopt:手机/桌面/对外隧道,按需装)缺失只提示、不判负。
bad=0
chk(){    # 核心:失败判负
  if systemctl is-active --quiet "$1"; then echo "  ✓ $1 ($2)"
  else echo "  ❌ $1 ($2) —— 恢复: $3"; bad=1; fi
}
chkopt(){ # 可选:未装/未起只提示,不判负
  if systemctl is-active --quiet "$1"; then echo "  ✓ $1 ($2)"
  else echo "  ⏭ $1 ($2) —— 可选层,未装/未起可忽略;要用: $3"; fi
}
echo "-- 核心常驻(必须 active) --"
chk cloud-watchdog.timer         "会话断电自愈(每15s)"     "systemctl enable --now cloud-watchdog.timer"
chk cloud-sessions.service       "开机拉起 watchdog"        "systemctl restart cloud-sessions.service"
chk tailscaled.service           "中美加密内网(命脉)"      "tailscale up"
chk fail2ban.service             "SSH 防爆破"               "systemctl restart fail2ban"
echo "-- 可选层(按需装,缺失不判负) --"
chkopt moshi-hook.service           "hub发送+手机审批 daemon"  "moshi-hook update 装二进制 + 配对(见 phone/README.md)"
chkopt moshi-hook-healthcheck.timer "daemon卡死自愈兜底"       "systemctl enable --now moshi-hook-healthcheck.timer"
chkopt novnc.service                "服务器 GUI 桌面 :6080"    "装图形桌面层(见桌面层文档)"
chkopt cloud-dashboards.service     "项目看板 :8088"           "systemctl restart cloud-dashboards.service"
chkopt cloudflared.service          "对外域名隧道(作者专属)"  "作者环境专用,客户一般不需要"
echo "-- 功能探活 --"
if timeout 12 /root/.local/bin/moshi-hook status >/dev/null 2>&1; then
  echo "  ✓ moshi-hook daemon socket 响应"
else
  echo "  ⏭ moshi-hook socket 无响应(可选层未装/未配对可忽略)"
fi
[ "$bad" = 0 ] && echo "== 核心基建全绿 ==" || echo "== 核心有 ❌,按上面提示恢复 =="
exit $bad
