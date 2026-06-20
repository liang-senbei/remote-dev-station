#!/usr/bin/env python3
# Claude Code 状态栏：模型 | 花费 | 上下文用量 | 套餐额度(5h/7d)
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

def g(path, default=None):
    cur = d
    for k in path.split('.'):
        if isinstance(cur, dict) and cur.get(k) is not None:
            cur = cur[k]
        else:
            return default
    return cur

def col(code, s):
    return f"\033[{code}m{s}\033[0m"

model = g('model.display_name', '?')
cost  = g('cost.total_cost_usd', 0) or 0
ctx   = g('context_window.used_percentage')
r5    = g('rate_limits.five_hour.used_percentage')
r7    = g('rate_limits.seven_day.used_percentage')

parts = [col('35', model), col('33', f"💰 ${cost:.3f}")]
if ctx is not None:
    parts.append(col('36', f"🪟 {int(ctx)}%"))
rl = []
if r5 is not None: rl.append(f"5h {int(r5)}%")
if r7 is not None: rl.append(f"7d {int(r7)}%")
if rl:
    parts.append(col('32', "⏳ " + " · ".join(rl)))

print("   ".join(parts))
