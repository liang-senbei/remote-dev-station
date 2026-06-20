#!/bin/bash
# Stop hook - 任务完成,Mac 播放 Xiaoxiao 语音
ssh -n mac "/usr/bin/afplay ~/.cc-voice/stop.mp3" 2>/dev/null &
