#!/usr/bin/env python3
# =====================================================================
# hub-gate.py —— PreToolUse 闸门:跨会话发消息「发送前必须人工确认」
# ---------------------------------------------------------------------
# 背景:多个 Claude Code(cc-*)会话并行跑,AI 容易"自作主张"用 hub 给别的
# 会话发消息,把对方上下文搞乱。本钩子在【消息真正发出前】拦下,弹确认给用户。
#
# 工作方式:读 stdin 的 PreToolUse JSON;若 Bash 命令里出现"跨会话发消息"动作,
# 就返回 permissionDecision:"ask"(附「发给谁+内容+条数」),由用户点 yes/no。
#   · --dangerously-skip-permissions(bypass)模式下 "ask" 仍会强制弹窗——
#     bypass 只跳过提示,显式 ask 强制的除外。这正是本闸门成立的依据。
#   · 拦的是写动作:hub say / hub ask / hub all(含全路径、bash -c 形式),
#     以及 raw `tmux send-keys` 打到 cc-* 会话。
#   · 只读的 hub ls / hub peek 不拦;非发消息的命令静默放行。
#
# 容错原则:本钩子在【每个 Bash 命令】上同步跑,所以任何内部异常都必须
#   fail-open(静默放行),绝不能因脚本自身出错而卡住无关命令。真正的硬保证
#   由 settings.json 里的 permissions.ask 规则独立兜底(脚本挂了规则照拦)。
# =====================================================================
import sys, json, re, shlex

# hub 发送子命令:行首/空白/shell 元字符/引号 之后的 (可选路径前缀/)hub say|ask|all
# 边界类排除字母数字,故 "github say" 里的内嵌 "hub" 不会误命中。
HUB_RE = re.compile(r"(?:^|[\s;&|()\"'`])(?:[^\s/]*/)*hub\s+(say|ask|all)\b")
# raw tmux 直接向某会话注入按键(绕过 hub):tmux send-keys ... 且目标是 cc-*
TMUX_SEND_RE = re.compile(r"\btmux\s+send-keys\b")
TMUX_CC_RE = re.compile(r"-t\s*[\"']?cc-")


def _clip(s, n=100):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n] + "…"


def _summarize_hub(cmd, matches):
    """从首个 hub 发送里解析 目标+正文,并统计本命令含几处发送。"""
    sub = matches[0].group(1)
    toks = []
    try:
        rest = cmd[matches[0].end():]
        seg = re.split(r"\s*(?:;|&&|\|\||\||\n)\s*", rest, maxsplit=1)[0]
        toks = shlex.split(seg)
    except Exception:
        toks = []
    if sub in ("say", "ask"):
        tgt = toks[0] if toks else "?"
        msg = _clip(" ".join(toks[1:])) if len(toks) > 1 else "(空)"
        verb = "发1条" if sub == "say" else "发1条并要求回信"
        head = f"给 cc:{tgt} {verb}：「{msg}」"
    else:  # all
        msg = _clip(" ".join(toks)) if toks else "(空)"
        head = f"【广播】给所有其它会话各发1条：「{msg}」"
    n = len(matches)
    if n > 1:
        head += f"；⚠️ 本命令共含 {n} 处 hub 发送"
    return head


def _decide(cmd):
    """返回需要弹确认的理由(str),或 None 表示放行。"""
    if "hub" in cmd:
        m = list(HUB_RE.finditer(cmd))
        if m:
            return "🚦 跨会话发消息 — " + _summarize_hub(cmd, m) + "。确认发给别的 Claude 会话吗?(只读的 hub ls/peek 不拦)"
    if TMUX_SEND_RE.search(cmd) and TMUX_CC_RE.search(cmd):
        return "🚦 跨会话发消息(raw tmux)— 命令试图用 tmux send-keys 直接向某个 cc-* 会话注入按键。确认吗?"
    return None


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return  # 输入解析不了 → 不干预
    if data.get("tool_name") != "Bash":
        return
    ti = data.get("tool_input") or {}
    cmd = ti.get("command")
    if not isinstance(cmd, str) or not cmd:
        return
    reason = _decide(cmd)
    if not reason:
        return  # 非跨会话发消息 → 静默放行
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": reason,
        }
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # 兜底:任何意外都不得阻断 Bash 命令(硬保证交给 permissions.ask 规则)
        pass
