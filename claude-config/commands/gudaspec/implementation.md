---
name: GudaSpec: Implementation
description: Execute approved OpenSpec changes via Codex plugin collaboration.
category: GudaSpec
tags: [openspec, implementation, codex]
---
<!-- GUDASPEC:START -->
**Guardrails**
- If the project is detected to lack `./openspec/` dir, prompt the user to initialize the project using `/gudaspec:init`.
- Never apply external model prototypes directly—all Codex outputs serve as reference only and must be rewritten into readable, maintainable, production-grade code.
- Keep changes tightly scoped to the requested outcome; enforce side-effect review before applying any modification.
- Minimize documentation—avoid unnecessary comments; prefer self-explanatory code.

**Steps**
1. Run `openspec view` to inspect current project status and review `Active Changes`;  Use `AskUserQuestions` tool ask the user to confirm which proposal ID they want to implement and wait for explicit confirmation before proceeding.
2. Run `/opsx:apply <proposal_id>` and then follow it.
3. When performing a specific coding task, use `codex:codex-rescue` subagent (Codex plugin) to get a code prototype as reference:
   - **Mandatory constraint**: When communicating with Codex, the prompt **must explicitly require** returning a `Unified Diff Patch` only; Codex is strictly forbidden from making any real file modifications.
4. Upon receiving the diff patch from Codex, **NEVER apply it directly**; rewrite the prototype by removing redundancy, ensuring clear naming and simple structure, aligning with project style, and eliminating unnecessary comments.
5. For each completed task, conduct code review using `codex:codex-rescue` subagent, requiring iterative reviews until receiving **LGTM approval**.
6. MUST follow the `/opsx:apply <proposal_id>`.
<!-- GUDASPEC:END -->
