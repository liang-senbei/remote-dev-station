#!/usr/bin/env python3
"""
disable-hub-gate.py —— 关掉 hub 闸门(与 enable-hub-gate.py 对称)。

为什么会想关:闸门要求跨会话发消息前人工点确认。这在「少数会话、怕 AI 乱发」时是对的,
但在【多 agent 高频协作】的场景下,每条消息都等人点 = 把自动化协作拖死。实际用下来
就是这个结论,所以默认不该开。

做法:精确移除本仓加的那两项(permissions.ask 的三条 hub 规则 + PreToolUse 里的
hub-gate 钩子),【其余一律不动】—— 不整份恢复备份,免得把期间的其它改动(比如换了
供应商、改了模型)一起回滚掉。hooks/hub-gate.py 文件保留,想再开随时 enable。
"""
import json, os, shutil, sys

HOME = os.path.expanduser("~")
SET = os.path.join(HOME, ".claude", "settings.json")
BAK = SET + ".bak-hubgate-off"
ASK_RULES = {"Bash(hub say *)", "Bash(hub ask *)", "Bash(hub all *)"}

if not os.path.exists(SET):
    print(f"⛔ {SET} 不存在", file=sys.stderr)
    sys.exit(1)

shutil.copyfile(SET, BAK)
s = json.load(open(SET, encoding="utf-8"))

# ① permissions.ask 去掉三条 hub 规则;空了就把键收掉,尽量还原成动手前的样子
removed_rules = 0
perms = s.get("permissions")
if isinstance(perms, dict) and isinstance(perms.get("ask"), list):
    before = len(perms["ask"])
    perms["ask"] = [r for r in perms["ask"] if r not in ASK_RULES]
    removed_rules = before - len(perms["ask"])
    if not perms["ask"]:
        del perms["ask"]

# ② PreToolUse 去掉 hub-gate 钩子(逐条看 command,只删含 hub-gate 的,cc-state 留着)
removed_hooks = 0
hooks = s.get("hooks") or {}
pre = hooks.get("PreToolUse")
if isinstance(pre, list):
    kept = []
    for item in pre:
        inner = [h for h in (item.get("hooks") or []) if "hub-gate" not in str(h.get("command", ""))]
        removed_hooks += len(item.get("hooks") or []) - len(inner)
        if inner:
            kept.append({**item, "hooks": inner})
        elif not item.get("hooks"):
            kept.append(item)          # 本来就没 hooks 的条目原样留着
    if kept:
        hooks["PreToolUse"] = kept
    else:
        del hooks["PreToolUse"]

tmp = SET + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write("\n")
json.load(open(tmp, encoding="utf-8"))        # 解析校验
os.replace(tmp, SET)
os.chmod(SET, 0o600)

print(f"① 已移除 permissions.ask 规则 {removed_rules} 条、PreToolUse 钩子 {removed_hooks} 个")

# ③ 复核:除这两项外什么都没动,且 cc-state 钩子必须还在
old = json.load(open(BAK, encoding="utf-8"))
new = json.load(open(SET, encoding="utf-8"))
for k, v in old.items():
    if k in ("permissions", "hooks"):
        continue
    assert new.get(k) == v, f"顶层键 {k} 被动了"
cc = json.dumps(new.get("hooks", {}).get("PreToolUse", []), ensure_ascii=False)
assert "cc-state" in cc, "cc-state 钩子被误删了!(会话状态登记会失效)"
for ev in old.get("hooks", {}):
    assert ev in new.get("hooks", {}), f"hooks.{ev} 丢了"
print("② 复核通过:env / 模型 / 其它钩子原样,cc-state 仍在")
print(f"   关闭前的快照: {BAK}")
print("   hooks/hub-gate.py 保留未删,想再开: python3 claude-config/enable-hub-gate.py")
