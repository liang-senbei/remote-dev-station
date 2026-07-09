#!/bin/bash
# 给 watch 用的一次性输出:格式化 claude agents --json,供"会话总览" widget 定时刷新显示。
/root/.local/bin/claude agents --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("(读取失败,claude agents --json 无输出或格式异常)")
    sys.exit(0)
if not d:
    print("(无会话)")
    sys.exit(0)
print(f"{'"'"'名称'"'"':30} {'"'"'类型'"'"':13} {'"'"'状态'"'"':8} 目录")
print("-" * 90)
for x in d:
    name = str(x.get("name", "?"))[:28]
    kind = str(x.get("kind", "?"))
    status = str(x.get("status") or x.get("state", "?"))
    cwd = str(x.get("cwd", "?"))
    print(f"{name:30} {kind:13} {status:8} {cwd}")
'
