---
name: GudaSpec: Init
description: Initialize OpenSpec environment with MCP tools validation for the current project.
category: GudaSpec
tags: [openspec, init, setup, mcp]
---
<!-- GUDASPEC:START -->
**Guardrails**
- Detect the current operating system (Linux, macOS, Windows) and adjust shell commands accordingly.
- All example commands below assume a Linux/Unix environment; adapt syntax for PowerShell on Windows if detected.
- Do not proceed to the next step until the current step completes successfully.
- Provide clear, actionable error messages when a step fails.
- Respect user's existing configurations and avoid overwriting without confirmation.

**Steps**
1. **Detect Operating System**
   - Identify the current OS using appropriate methods (`uname -s` on Unix-like systems, or environment variables on Windows).
   - Inform the user which OS was detected and note any command adaptations that will be made.

2. **Check and Install OpenSpec**
   - Verify if `openspec` CLI is installed by running `openspec --version` or `which openspec` (Linux/macOS) / `where openspec` (Windows).
   - If not installed, install globally using:
     ```bash
     npm install -g @fission-ai/openspec@latest
     ```
   - On Windows, use the same npm command in PowerShell or Command Prompt.
   - Confirm installation success by running `openspec --version` after installation.

3. **Initialize OpenSpec for Current Project**
   - Run the initialization command:
     ```bash
     openspec init --tools claude
     ```
   - Verify that `openspec/` directory structure is created successfully.
   - Report any initialization errors and suggest remediation steps.

4. **Validate Tools Availability**
   - Check if Codex CLI is installed by running `codex --version`.
   - If not installed, display a warning: "Codex CLI is not installed. Run `npm install -g @openai/codex` to install."
   - Codex is available as a plugin (`codex@openai-codex`) and can be invoked via the `codex:codex-rescue` subagent for subsequent GudaSpec workflows.

5. **Summary Report**
   - Display a summary of the initialization status:
     - OpenSpec installation: ✓/✗
     - Project initialization: ✓/✗
     - Codex CLI availability: ✓/✗

**Reference**
- OpenSpec CLI documentation: Run `openspec --help` for available commands.
- Codex CLI: `codex --help` or https://github.com/openai/codex
- For Node.js/npm issues, ensure Node.js >= 18.x is installed.
- On permission errors during global npm install, consider using `sudo` (Linux/macOS) or running terminal as Administrator (Windows), or configure npm to use a user-writable directory.
<!-- GUDASPEC:END -->
