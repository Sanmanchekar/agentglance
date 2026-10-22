# AgentGlance — Build Plan

> **Activity Monitor for AI agents: see what your AI started on your Mac, and switch it off when it's done.**

## 1. Problem
To test their work, coding agents (Claude Code, Codex, Gemini CLI) start dev servers, Docker containers, MCP servers, watchers and sub-agents. When a session ends, many of these keep running: 8 GB+ of orphaned Node processes, a dev server left for 2 days at 89% CPU, about 80 orphaned MCP servers filling 13 GB of swap (anthropics/claude-code #43944, #16198, #26658, #33947).

Activity Monitor can't tell which `node` belongs to which agent, so nothing can be cleaned up safely. Killing by port also hits your own processes. Existing tools (orphan-reaper, prune-agents) guess from "detached TTY" heuristics and have no idea of ownership.

## 2. What it does
1. **Ownership ledger:** for each agent session, the processes, listening ports, RAM and CPU it started, including after the agent has exited.
2. **Safe cleanup:** clean up everything a finished session left behind, and only that. Processes are killed by ownership, never by port or name.
3. **Warnings:** a port held by a leftover from an ended session, and (later) collisions between agents running at the same time.
4. **Machine pressure:** local-model memory (Ollama) next to agent usage.
5. **Later:** agent state (running / waiting), 5h/7d plan limits, and team mode.

## 3. How ownership is decided (in priority order)
1. **Live ancestry:** the process descends from a live agent root (`claude`, `codex`, `gemini`; a process counts as a root only when no ancestor is already a root).
2. **Inherited env tag:** Claude Code exports `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` to everything it spawns (verified on v2.1.308), so the tag survives re-parenting to launchd after the agent dies. Only an allow-list of env keys is read; tokens are never read.
3. **Ledger memory:** every ownership decision is persisted as `(pid, start time) → session` in `~/Library/Application Support/AgentGlance/ledger.json`, so tools without an env tag (Codex, Gemini) keep their attribution after re-parenting while the app was running.

`(pid, start time)` is the identity throughout, so a reused PID is never mistaken for an old process.

## 4. Safety rules for cleanup
- Only same-user processes. Never PID ≤ 1, never a live agent root, never this app.
- Re-check `(pid, start time)` right before every signal.
- SIGTERM, a 3 s grace period, then SIGKILL for survivors.
- By default only **ended** sessions are cleaned. A running session's processes are only killed one at a time, explicitly.
- `--dry-run` everywhere. The CLI asks for confirmation unless `--yes`.

## 5. Architecture
One Swift package, no third-party dependencies, macOS 14+:
- `AgentGlanceCore`: `ProcessReader` (libproc + `KERN_PROCARGS2`), `PortScanner` (`lsof` on owned PIDs only), `Attributor` (pure, unit-tested), `Ledger`, `Monitor`, `Cleaner`
- `agentglance` CLI: `ps [--json]`, `clean [--dry-run] [--yes] [--session KEY] [--pid N]`
- `AgentGlanceApp`: SwiftUI `MenuBarExtra`, no Dock icon, rescans every 3 s

## 6. Milestones
| # | Deliverable |
|---|---|
| **M1 (now)** | Core attribution for Claude, Codex and Gemini, ledger, ports, Ollama memory, safe cleanup, CLI, menu bar app |
| M2 | Docker containers (`docker ps` labels, compose working dir, `docker run` launched from an owned process) |
| M3 | Collision warnings: same port, same local DB/Redis, duplicate migration numbers across worktrees |
| M4 | Notifications ("session X ended and left 1.2 GB behind"), auto-clean rules, launch at login |
| M5 | Agent state via hooks, plan limits via the status line bridge |
| M6 | Signed and notarized `.app`, Homebrew cask |
| Later | Team mode: opt-in export of leak and usage stats |

## 7. Privacy
Everything stays local. It reads process metadata, an env allow-list and listening ports. It never reads prompt text and sends nothing over the network.
