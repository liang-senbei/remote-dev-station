#!/usr/bin/env python3
# Claude Code 状态栏：模型 │ 花费·上下文 │ 套餐额度(5h/7d + 刷新倒计时) —— 纯文字无 emoji，避免渲染挤位
import json, sys, datetime
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

def C(code, s):
    return f"\033[{code}m{s}\033[0m"

def fmt(mins):
    if mins <= 0:
        return "现在"
    dd, r = divmod(mins, 1440)
    h, m = divmod(r, 60)
    if dd:
        return f"{dd}d{h}h"
    if h:
        return f"{h}h{m}m"
    return f"{m}m"

def reset(path):
    v = g(path + '.resets_at')
    if v is None:
        return None
    try:
        ts = float(v)
        if ts > 1e12:
            ts /= 1000.0
        t = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        return fmt(int((t - now).total_seconds() // 60))
    except Exception:
        return None

model = g('model.display_name', '?')
cost  = g('cost.total_cost_usd', 0) or 0
ctx   = g('context_window.used_percentage')
r5    = g('rate_limits.five_hour.used_percentage')
r7    = g('rate_limits.seven_day.used_percentage')

SEP = C('90', '  │  ')
DOT = C('90', '  ·  ')

# 组1：模型
g1 = C('35', model)

# 组2：花费 + 上下文
res = [C('33', f"${cost:.2f}")]
if ctx is not None:
    res.append(C('36', f"ctx {int(ctx)}%"))
g2 = C('90', " · ").join(res)

# 组3：套餐额度（5h / 7d，余N=距刷新）
quota = []
if r5 is not None:
    s = C('32', f"5h {int(r5)}%")
    rr = reset('rate_limits.five_hour')
    if rr:
        s += C('90', " 余") + C('32', rr)
    quota.append(s)
if r7 is not None:
    s = C('32', f"7d {int(r7)}%")
    rr = reset('rate_limits.seven_day')
    if rr:
        s += C('90', " 余") + C('32', rr)
    quota.append(s)
g3 = DOT.join(quota) if quota else ""

groups = [g1, g2] + ([g3] if g3 else [])
print(SEP.join(groups))
