#!/usr/bin/env bash
# OOM 硬化（幂等，可重复跑）：防"单个 1M-context claude 会话 RAM 暴涨拖垮整机"。
# 实测过的失败模式——单进程涨到 6.7G，swap 却还剩 59%：swappiness 太低时内核宁可硬 OOM 也不换页。
# 四层：swap 兜底 + overcommit/swappiness + earlyoom 主动杀最肥 claude + user.slice 软顶。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
say(){ echo "  [oom] $*"; }

# 0) 必须 root（下面写 /etc、swapon、apt 全需要；非 root 会一路静默失败还报成功）
if [ "$(id -u)" != 0 ]; then echo "  [oom] ✗ 需 root：sudo bash $0" >&2; exit 1; fi

# 1) swap：判据是"有没有活动 swap"而非"文件在不在"——上次失败留下的 /swapfile 不能骗过检查。
#    fallocate 的文件在 Btrfs/ZFS 等 CoW FS 上 swapon 会拒、但 fallocate 仍返 0 → 必须【验 swapon】，失败退 dd。
ACT_SWAP_MB=$(free -m | awk '/Swap:/{print $2}')
if [ "${ACT_SWAP_MB:-0}" -lt 8000 ] && ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx /swapfile; then
  say "建 /swapfile 8G（现活动 swap ${ACT_SWAP_MB}MB）"
  swapoff /swapfile 2>/dev/null; rm -f /swapfile
  fallocate -l 8G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=8192 status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null
  if ! swapon /swapfile 2>/dev/null; then
    say "⚠️ swapon 拒了 fallocate 文件（多半 CoW FS），改 dd 连续文件重建"
    rm -f /swapfile
    dd if=/dev/zero of=/swapfile bs=1M count=8192 status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile 2>/dev/null
  fi
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx /swapfile; then
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    say "✓ swap 已启用（$(free -m | awk '/Swap:/{print $2}')MB）"
  else
    say "❌ swap 仍失败——查 dmesg | tail；未写 fstab"
  fi
else
  say "swap 足够（活动 ${ACT_SWAP_MB}MB）或 /swapfile 已是活动 swap，跳过"
fi

# 2) sysctl：overcommit=1（防大块虚拟内存预留崩）+ swappiness=60（肯用 swap 别死扛 RAM）
install -m644 "$HERE/sysctl-99-oom.conf" /etc/sysctl.d/99-oom.conf
if command -v sysctl >/dev/null 2>&1; then sysctl --system >/dev/null 2>&1
else echo 1 > /proc/sys/vm/overcommit_memory; echo 60 > /proc/sys/vm/swappiness; fi
say "sysctl overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null) swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)"

# 3) earlyoom：在 Ubuntu universe 源。本脚本可能早于 install.sh 开 universe → 这里【自己保证源+刷新】再装。
if ! command -v earlyoom >/dev/null 2>&1; then
  command -v add-apt-repository >/dev/null 2>&1 && add-apt-repository -y universe >/dev/null 2>&1
  apt-get update >/dev/null 2>&1
  apt-get install -y earlyoom >/dev/null 2>&1
fi
if command -v earlyoom >/dev/null 2>&1; then
  install -m644 "$HERE/earlyoom.default" /etc/default/earlyoom
  systemctl enable --now earlyoom >/dev/null 2>&1
  if systemctl is-active --quiet earlyoom; then say "✓ earlyoom 已启（核实 argv：systemctl show -p ExecStart earlyoom）"
  else say "⚠️ earlyoom 装了没起（journalctl -u earlyoom）"; fi
else
  say "❌ earlyoom 装不上（universe/apt 不可用），跳过——其余层仍生效"
fi

# 4) user.slice 软顶 = RAM×0.8。写 drop-in（持久）+ set-property --runtime（立即对运行中的 slice 生效）+ 读回验证。
RAM_MB=$(free -m | awk '/Mem:/{print $2}'); MEMHIGH="$(( RAM_MB * 8 / 10 ))M"
mkdir -p /etc/systemd/system/user.slice.d
sed "s/__MEMHIGH__/$MEMHIGH/" "$HERE/user-slice-memoryhigh.conf" > /etc/systemd/system/user.slice.d/50-memoryhigh.conf
systemctl daemon-reload 2>/dev/null
systemctl set-property --runtime user.slice MemoryHigh="$MEMHIGH" 2>/dev/null
NOW=$(systemctl show user.slice -p MemoryHigh --value 2>/dev/null)
say "user.slice MemoryHigh=$MEMHIGH（RAM ${RAM_MB}MB×0.8；读回 ${NOW:-?}）"

say "完成。核对：swapon --show ；sysctl vm.swappiness ；systemctl is-active earlyoom ；systemctl show user.slice -p MemoryHigh --value"
