# Upkeep 1.8.6

Claude Code and the Codex CLI can be moved to another install method from the Confirm updates screen.

## Why

The install methods do not get new versions at the same time. On 2026-11-03 winget offered Claude Code 2.1.302 while npm and Anthropic's own installer had 2.1.317. A Claude Code installed through winget stays behind until winget's manifest catches up, and Upkeep had no way to move it.

## Detection before the run

When Upkeep checks for updates, it also runs `steps\Update-AiClis.ps1 -Detect`. That reports, for each tool it finds, every install (npm, the tool's own installer, winget) with its version, and the newest version each method offers. Nothing is changed. On the PC these numbers come from, the check took about 4 seconds.

## The choice

Confirm updates has a "Claude Code / Codex CLI" section. Each tool shows its current install and, when another method has a newer version, says which one in amber. An "Update with" menu offers:

- keep as is (the default);
- npm;
- own installer (Claude Code only, through Anthropic's documented `irm https://claude.ai/install.ps1 | iex`);
- WinGet.

The choice is saved to `settings.json` under `AiCliChannels`, for example `{"claude-code": "npm", "codex": ""}`. Runs started from `SystemUpdate_Topgrade.bat` read the same setting.

## What a switch does

The new method is installed first, as the normal desktop user, and its version is read back. Only after that are the other installs removed (`npm uninstall -g`, `winget uninstall`, or the own installer's files). When the new install fails, the old one is kept and the end-of-run list gives the reason and the command. When the old install can't be removed because the tool is running, it is listed with the command to run after closing it.

The winget step does not upgrade `Anthropic.ClaudeCode` or `OpenAI.Codex` first when the chosen method is npm or the own installer. A chosen switch also runs when "Developer tools and other updaters" is unchecked; in that case the step only switches, and reports `skipped` when nothing needed to move.

## Validation

- 164 PowerShell tests pass under Windows PowerShell 5.1. Four are new: npm is installed before the winget install is removed; a failed npm install keeps the winget one; the detection output; the switch-only mode with nothing to do.
- 77 Rust tests pass, two of them new (pointing out a newer method; when a choice counts as a pending switch). The layout test now draws the new section in English and Portuguese at all five window sizes without clipped text.
- Detection on the PC from these logs found Claude Code through npm 2.1.317 (winget offering 2.1.302) and the Codex CLI through its own installer 0.166.0. A switch-only run there with no switch chosen changed nothing and exited 4.
