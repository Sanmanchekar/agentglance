# AgentGlance

**Activity Monitor for AI agents.** See what Claude Code, Codex and Gemini CLI started on your Mac (dev servers, MCP servers, watchers, sub-agents, Docker containers), and switch it off when they're done.

```
● claude  login-page (e77adda0)     running · 3 procs · 412 MB
○ claude  fix-tests  (9b1c22aa)     ENDED · left 2 procs · 1.2 GB
      48211  node   :3000   812 MB
      48230  esbuild        390 MB
```

- [Why](#why)
- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Install](#install)
- [First-run setup (macOS permissions)](#first-run-setup-macos-permissions)
- [Using the menu bar app](#using-the-menu-bar-app)
- [App settings](#app-settings)
- [CLI reference](#cli-reference)
- [How it knows who started what](#how-it-knows-who-started-what)
- [Privacy and safety](#privacy-and-safety)
- [Troubleshooting](#troubleshooting)
- [Update and uninstall](#update-and-uninstall)
- [Build from source](#build-from-source)
- [License](#license)

## Why
Agents leave background processes running after a session ends. Activity Monitor can't tell which `node` belongs to which agent, so you can't clean up safely. AgentGlance tracks **ownership**: each process is tied to the agent session that started it, even after the agent exits.

## What it does
| Feature | What you get |
|---|---|
| **Who started what** | Every process and Docker container, tied to the agent session that started it, even after the agent exits. |
| **Safe cleanup** | One click (or `agentglance clean`) stops what *ended* sessions left behind, and nothing else. |
| **Clash warnings** | Two agents editing the same folder, the same migration number added in two worktrees, ports held by leftovers. |
| **Who needs you** | Each Claude Code session shows *working*, *your turn* or *needs permission*; the menu bar shows a 🔔 count. Needs `agentglance install`. |
| **Plan limits** | Your Claude 5-hour and weekly usage as gauges, and the 5-hour % in the menu bar. Needs `agentglance install`. |
| **Notifications** | "fix-tests ended but left 3 procs · 1.2 GB running", with a **Clean up** button. Optional auto-clean. |

## Requirements
- macOS 14 (Sonoma) or later, Apple silicon or Intel
- Optional: Docker (Docker Desktop, Homebrew, Rancher Desktop or OrbStack) for container tracking
- Optional: Claude Code, for session state and plan limits

## Install
```bash
brew install sanmanchekar/tap/agentglance              # CLI
brew install --cask sanmanchekar/tap/agentglance-app   # menu bar app
agentglance install                                    # optional: Claude Code state + limits
```
Then complete the [first-run setup](#first-run-setup-macos-permissions) below.

## First-run setup (macOS permissions)
AgentGlance needs no special privacy permissions (no Full Disk Access, no Accessibility). There are only these steps:

### 1. Allow the app to open
The app is ad-hoc signed but **not notarized yet**, so macOS blocks the first launch. Do **one** of:

- **Terminal:** `xattr -dr com.apple.quarantine /Applications/AgentGlance.app`
- **System Settings:** open AgentGlance once, click **Done** on the warning, then go to **System Settings → Privacy & Security**, scroll to *Security*, and click **Open Anyway** next to "AgentGlance was blocked".

### 2. Allow notifications
On first launch macOS asks *"AgentGlance would like to send notifications"*: click **Allow**.
If you missed it: **System Settings → Notifications → AgentGlance** → turn on **Allow notifications** (style *Alerts* keeps the **Clean up** button on screen until you act).

### 3. Launch at login (optional)
In the app: **⚙ → Launch at login**.
macOS then lists it under **System Settings → General → Login Items & Extensions → Open at Login**. If it is switched off there, the in-app toggle can't turn it back on, so enable it in System Settings.

### 4. Connect Claude Code (optional)
```bash
agentglance install --dry-run   # preview the changes
agentglance install             # apply them
```
This edits `~/.claude/settings.json` (a timestamped backup is saved next to it):
- adds a `hook` entry to 10 Claude Code events, which records whether each session is working or waiting for you;
- wraps your status line as `agentglance statusline -- <your old command>`, which saves your plan limits and then runs your status line unchanged.

Existing hooks (e.g. iTerm2's) are kept. Restart open Claude Code sessions to pick it up.

## Using the menu bar app
The menu bar icon shows the most urgent thing, plus your 5-hour limit:

| Icon | Meaning |
|---|---|
| ⚠ `1.2 GB · 5%` | Ended sessions left programs running, using this much memory |
| 🔔 `2 · 5%` | Agents waiting for you (your turn or a permission prompt) |
| CPU `3 · 5%` | Agents running; nothing needs you |

Click it to open the panel:
- **Plan limits:** 5-hour and weekly gauges. After a window resets while you're idle it shows 0% ("starts with your next message"). Values refresh while a Claude Code session is open.
- **Warnings:** clashes and ports held by leftovers.
- **Left behind:** ended sessions with programs still running, with **Clean up** per session and **Clean up all**. This section (and its button) only appears when there is something to clean.
- **Running agents:** every live session with its activity, processes (memory, ports) and containers. ✕ stops a single process.
- **Local models:** Ollama, if running.

## App settings
All settings are in the **⚙** menu at the bottom of the panel.

| Setting | Default | What it does |
|---|---|---|
| **Launch at login** | Off | Starts AgentGlance when you log in (see [step 3](#3-launch-at-login-optional)). |
| **Notify when a session leaves things running** | On | Sends a notification with a **Clean up** button when a session ends and leaves programs behind, and when a new clash appears. Requires notifications to be allowed in System Settings. |
| **Auto-clean leftovers** | Off | Stops leftovers automatically **10 minutes** or **1 hour** after a session ends. Only processes and *confirmed* containers; Mac apps are never auto-stopped. |
| **Quit AgentGlance** | | Quits the app. |

## CLI reference
```
agentglance [ps] [--json] [--no-docker]     show sessions and what each one started (default)
agentglance clean [--dry-run] [--yes]       stop everything ended sessions left behind
            [--session KEY]...              only these sessions (key or short session ID)
            [--pid PID]...                  exactly these processes, even from a running session
            [--container ID]...             exactly these containers, even "likely" ones
agentglance install [--dry-run]             connect Claude Code (hooks + status line)
agentglance uninstall [--dry-run]           disconnect it again
agentglance --version
```
`agentglance hook` and `agentglance statusline` are called by Claude Code; you don't run them yourself.

Examples:
```bash
agentglance                       # what's running and who started it
agentglance clean --dry-run       # what would be stopped
agentglance clean --session 9b1c22aa
agentglance ps --json | jq .
```

## How it knows who started what
1. **Live ancestry:** the process descends from a running `claude`, `codex` or `gemini`.
2. **Inherited tag:** Claude Code stamps `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` into every process it spawns, so leftovers stay traceable after Claude exits.
3. **Ledger memory:** ownership is remembered as `(pid, start time) → session`, so other agents' leftovers stay traceable too, and a reused PID is never confused with an old process.

Containers are **confirmed** when the session's own `docker` command was seen just before the container was created, and **likely** when only the folder matches.

## Privacy and safety
- **Everything stays local.** No network calls, no telemetry. State lives in `~/Library/Application Support/AgentGlance`.
- **Reads only what it needs.** Process names, paths, memory, CPU and listening ports, plus a fixed allow-list of environment variables (`CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID`, `CLAUDECODE`, `AI_AGENT`, `PWD`). Tokens and other env vars are never read.
- **Cleanup is conservative.** It only touches **ended** sessions (or the exact PIDs/containers you name), re-checks each process's identity before signalling it, and sends SIGTERM, then SIGKILL after 3 s. Containers get `docker stop`, never `rm`. Bulk cleanup skips Mac apps and *likely* containers.

See [docs/PLAN.md](docs/PLAN.md) for the design, the safety rules and the roadmap.

## Troubleshooting
| Problem | Fix |
|---|---|
| "AgentGlance can't be opened" / "Apple could not verify…" | See [step 1](#1-allow-the-app-to-open). |
| No notifications | System Settings → Notifications → AgentGlance → Allow notifications; and ⚙ → *Notify…* is on. |
| No 🔔 / activity or no limit gauges | Run `agentglance install`, then restart Claude Code sessions. Limits need a Pro/Max plan. |
| Limits look old | They refresh while a Claude Code session is open; the panel shows "Updated N min ago". |
| No **Clean up all** button | Nothing is left behind; it appears only when an ended session left programs running. |
| Containers missing | Start Docker; the panel says when Docker isn't running. |
| Launch at login doesn't stick | Turn it on under System Settings → General → Login Items & Extensions. |

## Update and uninstall
```bash
# update
brew update && brew upgrade sanmanchekar/tap/agentglance
brew upgrade --cask sanmanchekar/tap/agentglance-app

# uninstall
agentglance uninstall                                  # restore ~/.claude/settings.json entries
brew uninstall --cask --zap sanmanchekar/tap/agentglance-app
brew uninstall sanmanchekar/tap/agentglance
```

## Build from source
```bash
swift build -c release
.build/release/agentglance ps
./scripts/bundle.sh && open build/AgentGlance.app   # menu bar app
./scripts/test.sh                                   # tests
```

## License
[MIT](LICENSE) © 2026 Sushant Manchekar
