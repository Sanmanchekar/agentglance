# AgentGlance

**Activity Monitor for AI agents.** See what Claude Code, Codex and Gemini CLI started on your Mac (dev servers, MCP servers, watchers, sub-agents), and switch it off when they're done.

```
● claude  login-page (e77adda0)     running · 3 procs · 412 MB
○ claude  fix-tests  (9b1c22aa)     ENDED · left 2 procs · 1.2 GB
      48211  node   :3000   812 MB
      48230  esbuild        390 MB
```

## What it does
- **Who started what:** every process (dev servers, MCP servers, watchers) and Docker container, tied to the agent session that started it, even after the agent exits.
- **Safe cleanup:** one click (or `agentglance clean`) stops what ended sessions left behind, and nothing else.
- **Clash warnings:** two agents editing the same folder, the same migration number added in two worktrees, ports held by leftovers.
- **Who needs you:** each Claude session shows *working*, *your turn* or *needs permission*, and the menu bar shows a 🔔 count. Your 5-hour and weekly plan limits appear as gauges. Run `agentglance install` once to enable this.
- **Notifications:** "fix-tests ended but left 3 procs · 1.2 GB running" with a Clean up button. Optional auto-clean, launch at login.

## Why
Agents leave background processes running after a session ends. Activity Monitor can't tell which `node` belongs to which agent, so you can't clean up safely. AgentGlance tracks **ownership**: each process is tied to the agent session that started it, even after the agent exits.

## Install
```bash
brew install sanmanchekar/tap/agentglance          # CLI
brew install --cask sanmanchekar/tap/agentglance-app   # menu bar app
agentglance install                                 # optional: Claude Code state + limits
```
The app isn't notarized yet. If macOS says it can't be opened, run
`xattr -dr com.apple.quarantine /Applications/AgentGlance.app` once, or allow it in System Settings → Privacy & Security.

## Build from source
```bash
swift build -c release
.build/release/agentglance ps            # who started what
.build/release/agentglance clean --dry-run
.build/release/agentglance clean         # stop everything ended sessions left behind
./scripts/bundle.sh && open build/AgentGlance.app   # menu bar app
.build/release/agentglance install --dry-run   # preview the Claude Code hooks + status line bridge
./scripts/test.sh                        # tests
```

## How it knows who started what
1. **Live ancestry:** the process descends from a running `claude`, `codex` or `gemini`.
2. **Inherited tag:** Claude Code stamps `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` into every process it spawns, so leftovers stay traceable after Claude exits.
3. **Ledger memory:** ownership is remembered as `(pid, start time) → session`, so other agents' leftovers stay traceable too, and a reused PID is never confused with an old process.

Containers are **confirmed** when the session's own `docker` command was seen just before the container was created, and **likely** when only the folder matches. Only confirmed ones are included in bulk cleanup (`docker stop`, never `rm`).

Cleanup only touches processes from **ended** sessions (or single PIDs you name), re-checks each process's identity before signalling it, and sends SIGTERM, then SIGKILL after 3 s.

See [docs/PLAN.md](docs/PLAN.md) for the design, the safety rules and the roadmap. Everything stays local.

## License
[MIT](LICENSE) © 2026 Sushant Manchekar
