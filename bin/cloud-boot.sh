#!/bin/bash
# 开机恢复:不再一次性 mass-resume 全部会话(那会 OOM 雪崩 —— 14 个重会话一起起,内存爆)。
# 改为只确保【内存守卫版 watchdog】定时器在跑,由它温和恢复(每轮看内存、最多 1 个,装满即止)。
# 单一恢复逻辑(开机/运行期同一套),从根上杜绝恢复风暴。
export PATH="/root/.local/bin:/usr/local/bin:/usr/bin:/bin"
tmux start-server 2>/dev/null || true
systemctl start cloud-watchdog.timer 2>/dev/null || true
exit 0
