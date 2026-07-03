#!/bin/bash
# Notification hook - 需要决策
ssh -n mac "/usr/bin/afplay ~/.cc-voice/notification.mp3" 2>/dev/null &
{ tty=$(tmux display -p -t "${TMUX_PANE:-}" "#{pane_tty}" 2>/dev/null); printf "\a" > "${tty:-/dev/tty}"; } 2>/dev/null
