#!/usr/bin/env python3
"""
enable-hub-gate.py —— 把 hub 闸门接到实际生效的 ~/.claude/ 上。

「跨会话发消息前必须人工确认」是本仓的硬规则,但 install.sh 只铺最小模板
(settings.client.json,仅 cc-state 钩子),【不装 hooks/】—— 所以规则默认是不生效的
(2026-08-01 在自用服务器上核实:hooks 目录根本不存在,一道拦截都没有)。
想让规则落地就跑这个脚本;不想要就别跑,互不影响。

用法: python3 claude-config/enable-hub-gate.py

原则:
  · settings.json 里有真实 API Key 等私货 —— 只【追加】hub 相关两项,其余原样不动;
  · PreToolUse 已被 cc-state 占用 —— 追加到数组里,绝不覆盖(覆盖=会话状态登记全废);
  · 先备份、改完校验 JSON 能解析,失败自动回滚。
"""
import json, os, shutil, sys, subprocess

HOME = os.path.expanduser("~")
SET = os.path.join(HOME, ".claude", "settings.json")
BAK = SET + ".bak-hubgate"
REPO = os.path.dirname(os.path.abspath(__file__))          # 本脚本就放在 claude-config/ 里
HOOKS_DST = os.path.join(HOME, ".claude", "hooks")
GATE = os.path.join(HOOKS_DST, "hub-gate.py")
PY = sys.executable or "/usr/bin/python3"

ASK_RULES = ["Bash(hub say *)", "Bash(hub ask *)", "Bash(hub all *)"]
GATE_CMD = f"{PY} {GATE}"

# ---- 1) 装脚本 ----
os.makedirs(HOOKS_DST, exist_ok=True)
src = os.path.join(REPO, "hooks", "hub-gate.py")
shutil.copyfile(src, GATE)
os.chmod(GATE, 0o755)
print(f"① 已装 {GATE}")

# 自检:脚本本身能跑,且对"普通命令"静默放行、对"hub say"给出 ask
def probe(cmd):
    p = subprocess.run([PY, GATE], input=json.dumps(
        {"tool_name": "Bash", "tool_input": {"command": cmd}}), capture_output=True, text=True, timeout=10)
    return p.stdout.strip()

assert probe("ls -la") == "", "普通命令不该被拦"
out = probe('hub say foo "hi"')
assert '"permissionDecision": "ask"' in out, f"hub say 应触发 ask,实际: {out!r}"
assert probe('hub ls') == "", "只读的 hub ls 不该被拦"
assert '"ask"' in probe('tmux send-keys -t cc-foo "x" Enter'), "raw tmux 注入应被拦"
print("② 闸门自检通过(普通命令放行 / hub say 拦 / hub ls 放行 / raw tmux 拦)")

# ---- 2) 改 settings.json:只追加,不覆盖 ----
if not os.path.exists(SET):
    print(f"⛔ {SET} 不存在 —— 先跑 install.sh 铺好基础配置再来。", file=sys.stderr)
    sys.exit(1)
shutil.copyfile(SET, BAK)
s = json.load(open(SET, encoding="utf-8"))

perms = s.setdefault("permissions", {})
ask = perms.setdefault("ask", [])
added_rules = [r for r in ASK_RULES if r not in ask]
ask.extend(added_rules)

hooks = s.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
already = any(GATE in json.dumps(item, ensure_ascii=False) for item in pre)
if not already:
    pre.append({"matcher": "Bash", "hooks": [{"type": "command", "command": GATE_CMD, "timeout": 10}]})

tmp = SET + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write("\n")
json.load(open(tmp, encoding="utf-8"))          # 解析校验,坏了就不 rename
os.replace(tmp, SET)
os.chmod(SET, 0o600)
print(f"③ settings.json 已更新(permissions.ask +{len(added_rules)} 条;PreToolUse "
      f"{'追加了闸门' if not already else '本来就有,未重复加'})")

# ---- 3) 复核:原有内容一个没丢 ----
old = json.load(open(BAK, encoding="utf-8"))
new = json.load(open(SET, encoding="utf-8"))
lost = []
for k, v in old.items():
    if k in ("permissions", "hooks"):
        continue
    if new.get(k) != v:
        lost.append(k)
assert not lost, f"顶层键被改动: {lost}"
old_pre = old.get("hooks", {}).get("PreToolUse", [])
assert all(item in new["hooks"]["PreToolUse"] for item in old_pre), "原有 PreToolUse 被挤掉了!"
for ev in old.get("hooks", {}):
    assert ev in new["hooks"], f"hooks.{ev} 丢了"
print("④ 复核通过:env/模型/其它 hooks 事件原样保留,原 PreToolUse(cc-state)还在")
print(f"   备份: {BAK}")
