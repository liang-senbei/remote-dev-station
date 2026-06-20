#!/bin/bash
# Error hook - 出错了
ssh -n mac "/usr/bin/afplay ~/.cc-voice/error.mp3" 2>/dev/null &
