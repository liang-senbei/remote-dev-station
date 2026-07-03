#!/bin/bash
# Stop hook - 任务完成,Mac 播放 Xiaoxiao 语音
ssh -n mac "/usr/bin/afplay ~/.cc-voice/stop.mp3" 2>/dev/null &
{ tty=$(tmux display -p -t "${TMUX_PANE:-}" "#{pane_tty}" 2>/dev/null); printf "\a" > "${tty:-/dev/tty}"; } 2>/dev/null
