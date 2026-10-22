# AgentGlance — Build Plan

## 1. Goal
AgentGlance is about **plan limits and agent state, not cost.** The menu bar item looks like `5h 23% · 7d 41% · ● 2 running · 1 waiting`. Clicking it opens a panel with:
- **Limits:** the 5-hour window (the "today" view) and the 7-day window, each with % used, a reset countdown and a pace projection ("at this rate you hit the 5h limit at 16:40")
- **Sessions:** one row per live session with tool, project/cwd, model, state and a tok/s sparkline
- **Notifications:** when a session flips to `awaiting_input`, and when a limit crosses 75% / 90% or is projected to run out before it resets

> Claude plans have no daily limit. They use a rolling **5-hour** window and a **7-day** window, so the 5-hour window stands in for "today".

## 2. Architecture

```
 ┌─────────────── sources ───────────────┐
 │ JSONL tailers   (Claude, Codex)       │
 │ Hook events     (Claude hooks → sock) │──► Event bus ──► Session store ──► SwiftUI MenuBarExtra
 │ OTLP receiver   (Gemini, Claude OTel) │    (normalise)   (in-mem + SQLite)   (status item + panel)
 │ Status line bridge (Claude limits)    │                       │
 │ Ollama proxy + /api/ps poll           │                  Limits engine
 │ PTY wrapper     (`agentglance run`)   │              (windows, pace, alerts)
 └───────────────────────────────────────┘
```

One Swift Package with these targets:
- `AgentGlanceCore`: adapters, event model, session state machine, limits engine, storage (no UI, fully unit-tested)
- `AgentGlanceApp`: SwiftUI `MenuBarExtra` (macOS 13+), Swift Charts sparklines, `UserNotifications`
- `agentglance` CLI: `run -- <cmd>` (PTY wrapper), `emit <event>` (hook helper), `statusline -- <your existing statusline cmd>` (limits bridge), `install-hooks`, `status --json`

Libraries: GRDB (SQLite), swift-argument-parser. File watching uses `DispatchSource`/FSEvents. The socket at `~/Library/Application Support/AgentGlance/agentglance.sock` uses Network.framework.

### Normalised event
```swift
enum AgentState { case running, awaitingInput, idle, error, ended }
struct UsageEvent { tool, sessionId, cwd, model, requestId, ts,
                    input, output, cacheWrite5m, cacheWrite1h, cacheRead }
struct StateEvent { tool, sessionId, state, ts, reason }
struct LimitEvent { tool, window /* fiveHour | sevenDay */, usedPct, resetsAt, ts }
```

## 3. Sources: what is real and what has limits

| Source | Usage/cost | State | Fidelity |
|---|---|---|---|
| **Claude Code status line** (documented) | `rate_limits.five_hour` / `seven_day` → `used_percentage`, `resets_at` (Pro/Max only, after the first response) | — | **exact plan limits**, refreshed every turn |
| **Claude Code JSONL** (verified locally) | `message.usage` per assistant line: input, output, `cache_creation.ephemeral_5m/1h`, cache_read, `model`, `requestId` | inferred from the last entry type plus mtime | per-turn, not per-token |
| **Claude Code hooks** | — | `UserPromptSubmit`/`PreToolUse` → running, `Notification` → awaiting_input, `Stop` → idle, `SessionEnd` → ended | exact, instant |
| **Codex CLI** | `token_count` events in rollout JSONL; these reportedly carry `rate_limits` (primary/secondary window %), **to verify** | inferred | per-turn |
| **Gemini CLI** | OTLP token metrics | inferred | per-request |
| **Ollama** | proxy on `:11435` → `:11434` reads `eval_count`/`eval_duration` from responses | `/api/ps` (model loaded) plus proxy in-flight count | **true tok/s** |
| **PTY wrapper** | — (or a regex per tool) | output activity, idle timeout, prompt patterns | generic fallback |

**Gotchas we already know about**
- A Claude JSONL file can repeat a `requestId` across several lines (one per content block). **Dedupe by `requestId`** or the cost is overcounted.
- Sub-agent and sidechain lines (`isSidechain`) belong to the parent session.
- `rate_limits` is absent until the session's first response, each window can be missing on its own, and Claude Code drops a window once `resets_at` passes. Keep the last known value and gray it out instead of showing 0%.
- Limits are per **account**, not per session, so every Claude session reports the same windows. Keep the most recent reading per account.
- The user already has a custom status line. The bridge must **wrap** it: tee stdin to the socket, then exec their command unchanged, and never add latency or output.
- Log formats are undocumented and change. Each adapter has a version guard and fixture tests, and degrades to "unknown" instead of crashing.
- Tok/s from JSONL is `output_tokens / turn duration` (gap from the previous entry). Label it "avg"; only the Ollama proxy and the PTY wrapper see streaming.

## 4. State machine (per session)
```
idle ──prompt──► running ──Notification──► awaiting_input ──prompt──► running
  ▲                 │ Stop                                         
  └─────────────────┘        no activity for N min ──► idle ;  SessionEnd / pid gone ──► ended
```
Hooks are authoritative when present. Otherwise the JSONL heuristic applies: a last line of `assistant` with `tool_use` means running, a last line of `assistant` with an end turn means idle, and no writes for 10 min means idle.

## 5. Limits engine
- **Source of truth:** the latest `LimitEvent` per tool and window. It is only refreshed when an agent turn runs; between turns, the countdown to `resets_at` keeps ticking locally.
- **Pace:** take the slope of `usedPct` over recent readings, plus the token rate from JSONL. Extrapolate when 100% is reached, then compare that time with `resets_at` to label the window on track, tight, or will run out.
- **Alerts:** at 75% and 90%, and when the projection says the limit runs out before it resets. Each alert fires once per window.
- **Fallback when there is no `rate_limits`** (API-key users, Codex/Gemini without limit data): show raw token totals for the window and no %.
- **No pricing and no $.** Cost is out of scope.

## 6. Storage
SQLite tables `usage(request_id PK, …)`, `sessions`, `state_changes`, `limit_readings(tool, window, used_pct, resets_at, ts)`. On first launch it backfills the last 30 days from JSONL. Byte offsets are checkpointed per file so restarts resume where they left off.

## 7. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | SPM scaffold, `MenuBarExtra` with a static label, GitHub Actions build | the app runs from Xcode and CI is green |
| M1 | Unix socket and `agentglance statusline` bridge (wraps the existing status line), limits engine, `5h % · 7d %` in the menu bar with reset countdowns | menu bar matches `/usage` in Claude Code; existing status line output unchanged |
| M2 | `agentglance emit` and `install-hooks` (shows the settings diff and asks consent), live state per session, awaiting-input notifications | state flips under 1 s after a hook fires |
| M3 | Claude JSONL adapter (tok/s, token totals), pace projection, limit alerts, panel UI with sparklines, launch at login | usable daily |
| M4 | Codex adapter (including its rate-limit windows if confirmed) and Gemini OTLP adapter | fixture tests pass |
| M5 | Ollama proxy and `/api/ps`; `agentglance run` PTY wrapper | true tok/s for Ollama |
| M6 | Developer ID signing, notarization, Homebrew cask, Sparkle updates | `brew install --cask agentglance` |

## 8. Non-goals and constraints
- No App Store: the app needs to read `~/.claude`, `~/.codex` and similar folders without the sandbox, so it ships as a notarized Developer ID build.
- It never reads or stores prompt or response text, only usage and limit fields.
- It does not track or estimate cost.
- It never edits agent config silently. Hook install is explicit and reversible (`uninstall-hooks`).

## 9. Later: team mode
Out of scope for v1, but the design keeps the door open:
- The core already normalises everything into `UsageEvent` / `StateEvent` / `LimitEvent`, so team mode is an **opt-in exporter** that pushes those events (never prompt text) to a shared endpoint.
- Likely shape: a small server and a web dashboard showing who is near their limits and which agents are waiting on a human.
- Decide later: self-hosted only or hosted too, auth (GitHub org SSO), and per-user opt-in.
