#!/usr/bin/env bash
# OOM 硬化（幂等，可重复跑）：防"单个 1M-context claude 会话 RAM 暴涨拖垮整机"。
# 实测过的失败模式——单进程涨到 6.7G，swap 却还剩 59%：swappiness 太低时内核宁可硬 OOM 也不换页。
# 五层：swap 兜底 + overcommit/swappiness + earlyoom 主动杀最肥 claude + user.slice 软顶 + cc-reap 收空闲。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
say(){ echo "  [oom] $*"; }

# 1) swap：现有 <8G 且无 /swapfile 就建 8G（会话是重进程，swap 是 RAM 暴涨的缓冲）
SWAP_MB=$(free -m | awk '/Swap:/{print $2}')
if [ "${SWAP_MB:-0}" -lt 8000 ] && [ ! -f /swapfile ]; then
  say "建 /swapfile 8G（现 swap ${SWAP_MB}MB）"
  fallocate -l 8G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=8192 status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile \
    && { grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; }
else
  say "swap 足够（${SWAP_MB}MB）或 /swapfile 已存在，跳过"
fi

# 2) sysctl：overcommit=1（防 Bun 大块虚拟内存预留崩）+ swappiness=60（肯用 swap 别死扛 RAM）
install -m644 "$HERE/sysctl-99-oom.conf" /etc/sysctl.d/99-oom.conf
if command -v sysctl >/dev/null 2>&1; then sysctl --system >/dev/null 2>&1
else echo 1 > /proc/sys/vm/overcommit_memory; echo 60 > /proc/sys/vm/swappiness; fi
say "sysctl overcommit=1 swappiness=60"

# 3) earlyoom：RAM 见底主动杀最肥 claude，保 ssh/tmux/systemd（-s 100 = 只看 RAM 不等 swap 见底）
if apt-get install -y earlyoom >/dev/null 2>&1 || command -v earlyoom >/dev/null 2>&1; then
  install -m644 "$HERE/earlyoom.default" /etc/default/earlyoom
  systemctl enable --now earlyoom >/dev/null 2>&1 && say "earlyoom 已启" || say "⚠️ earlyoom 装了没起（查 systemctl status earlyoom）"
else
  say "⚠️ earlyoom 装不上（apt 不可用？），跳过——其余层仍生效"
fi

# 4) user.slice 软顶 = RAM×0.8，超了提前回收/换页
RAM_MB=$(free -m | awk '/Mem:/{print $2}'); MEMHIGH="$(( RAM_MB * 8 / 10 ))M"
mkdir -p /etc/systemd/system/user.slice.d
sed "s/__MEMHIGH__/$MEMHIGH/" "$HERE/user-slice-memoryhigh.conf" > /etc/systemd/system/user.slice.d/50-memoryhigh.conf
systemctl daemon-reload 2>/dev/null
say "user.slice MemoryHigh=$MEMHIGH（RAM ${RAM_MB}MB×0.8）"

# 5) cc-reap 定时（每 30min 杀空闲>180min 未 attach 会话；对话存档不删，claude --resume 可找回）
if [ -f "$HERE/../systemd/cc-reap.service" ]; then
  install -m644 "$HERE/../systemd/cc-reap.service" "$HERE/../systemd/cc-reap.timer" /etc/systemd/system/
  systemctl daemon-reload 2>/dev/null
  systemctl enable --now cc-reap.timer >/dev/null 2>&1 && say "cc-reap.timer 已启" || say "⚠️ cc-reap.timer 没起"
fi
say "完成。核对：systemctl is-active earlyoom cc-reap.timer ；cat /proc/sys/vm/swappiness（应=60）"
