#!/usr/bin/env python3
# =====================================================================
# hub-gate.py —— PreToolUse 闸门:跨会话发消息「发送前必须人工确认」
# ---------------------------------------------------------------------
# 背景:多个 Claude Code(cc-*)会话并行跑,AI 容易"自作主张"用 hub 给别的
# 会话发消息,把对方上下文搞乱。本钩子在【消息真正发出前】拦下,弹确认给用户。
#
# 2026-07-12 改:用户反馈"hub say/ask/all 要点两次确认太繁琐"(对话里先问一次
# +系统权限框再弹一次),明确选择"只留对话里问,去掉系统弹窗"这条路径。
# 于是 hub say/ask/all 这三个子命令改成【静默放行,不再强制 ask】——发送前的
# 人工确认现在**只**靠 CLAUDE.md 硬规则(agent 在对话里先问、列清发给谁/发
# 什么/几条,用户同意才发),不再有独立于 agent 之外的技术兜底。这是用户明确
# 要求放弃的兜底,不是疏忽——agent 必须更自觉地执行 CLAUDE.md 里那条硬规则。
# raw `tmux send-keys` 直接打到 cc-* 会话(绕过 hub 本身的口子)仍然拦,因为
# 那是另一条更隐蔽的旁路,用户没说要一并放开。
#
# 工作方式:读 stdin 的 PreToolUse JSON;若命令里出现"跨会话发消息"动作,
# 且不是走 hub say/ask/all 这条已改自觉确认的路径,则返回 permissionDecision:
# "ask"(附内容摘要),由用户点 yes/no。
#   · --dangerously-skip-permissions(bypass)模式下 "ask" 仍会强制弹窗——
#     bypass 只跳过提示,显式 ask 强制的除外。这正是本闸门成立的依据。
#
# 容错原则:本钩子在【每个 Bash 命令】上同步跑,所以任何内部异常都必须
#   fail-open(静默放行),绝不能因脚本自身出错而卡住无关命令。
# =====================================================================
import sys, json, re

# raw tmux 直接向某会话注入按键(绕过 hub):tmux send-keys ... 且目标是 cc-*
TMUX_SEND_RE = re.compile(r"\btmux\s+send-keys\b")
TMUX_CC_RE = re.compile(r"-t\s*[\"']?cc-")


def _decide(cmd):
    """返回需要弹确认的理由(str),或 None 表示放行。
    hub say/ask/all 本身 2026-07-12 起不再强制系统弹窗(改靠 agent 对话里
    自觉先问,见文件头说明);这里只保留 raw tmux send-keys 旁路的拦截。"""
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
        # 兜底:任何意外都不得阻断 Bash 命令,静默放行
        pass
