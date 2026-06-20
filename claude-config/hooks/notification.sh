#!/bin/bash
# Notification hook - 需要决策
ssh -n mac "/usr/bin/afplay ~/.cc-voice/notification.mp3" 2>/dev/null &
