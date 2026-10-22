# AgentGlance — Build Plan

## 1. Goal
A menu bar item such as `● 2 running · 1 waiting · $4.12 today`. Clicking it opens a panel with:
- one row per live session: tool, project/cwd, model, state, tok/s sparkline, session cost
- totals for today, this week and this month, plus an optional budget bar
- a notification when a session flips to `awaiting_input`

## 2. Architecture

```
 ┌─────────────── sources ───────────────┐
 │ JSONL tailers   (Claude, Codex)       │
 │ Hook events     (Claude hooks → sock) │──► Event bus ──► Session store ──► SwiftUI MenuBarExtra
 │ OTLP receiver   (Gemini, Claude OTel) │    (normalise)   (in-mem + SQLite)   (status item + panel)
 │ Ollama proxy + /api/ps poll           │                       │
 │ PTY wrapper     (`agentglance run`)   │                  Pricing engine
 └───────────────────────────────────────┘
```

One Swift Package with these targets:
- `AgentGlanceCore`: adapters, event model, session state machine, pricing, storage (no UI, fully unit-tested)
- `AgentGlanceApp`: SwiftUI `MenuBarExtra` (macOS 13+), Swift Charts sparklines, `UserNotifications`
- `agentglance` CLI: `run -- <cmd>` (PTY wrapper), `emit <event>` (hook helper), `install-hooks`, `status --json`

Libraries: GRDB (SQLite), swift-argument-parser. File watching uses `DispatchSource`/FSEvents. The socket at `~/Library/Application Support/AgentGlance/agentglance.sock` uses Network.framework.

### Normalised event
```swift
enum AgentState { case running, awaitingInput, idle, error, ended }
struct UsageEvent { tool, sessionId, cwd, model, requestId, ts,
                    input, output, cacheWrite5m, cacheWrite1h, cacheRead }
struct StateEvent { tool, sessionId, state, ts, reason }
```

## 3. Sources: what is real and what has limits

| Source | Usage/cost | State | Fidelity |
|---|---|---|---|
| **Claude Code JSONL** (verified locally) | `message.usage` per assistant line: input, output, `cache_creation.ephemeral_5m/1h`, cache_read, `model`, `requestId` | inferred from the last entry type plus mtime | per-turn, not per-token |
| **Claude Code hooks** | — | `UserPromptSubmit`/`PreToolUse` → running, `Notification` → awaiting_input, `Stop` → idle, `SessionEnd` → ended | exact, instant |
| **Claude Code OTel** (`CLAUDE_CODE_ENABLE_TELEMETRY=1`) | `claude_code.cost.usage`, `token.usage` | — | optional cross-check |
| **Codex CLI** | `token_count` events in rollout JSONL | inferred | per-turn |
| **Gemini CLI** | OTLP token metrics | inferred | per-request |
| **Ollama** | proxy on `:11435` → `:11434` reads `eval_count`/`eval_duration` from responses | `/api/ps` (model loaded) plus proxy in-flight count | **true tok/s** |
| **PTY wrapper** | — (or a regex per tool) | output activity, idle timeout, prompt patterns | generic fallback |

**Gotchas we already know about**
- A Claude JSONL file can repeat a `requestId` across several lines (one per content block). **Dedupe by `requestId`** or the cost is overcounted.
- 5m and 1h cache writes are priced differently, so keep them separate.
- Sub-agent and sidechain lines (`isSidechain`) count toward cost but belong to the parent session.
- Log formats are undocumented and change. Each adapter has a version guard and fixture tests, and degrades to "unknown" instead of crashing.
- Tok/s from JSONL is `output_tokens / turn duration` (gap from the previous entry). Label it "avg"; only the Ollama proxy and the PTY wrapper see streaming.

## 4. State machine (per session)
```
idle ──prompt──► running ──Notification──► awaiting_input ──prompt──► running
  ▲                 │ Stop                                         
  └─────────────────┘        no activity for N min ──► idle ;  SessionEnd / pid gone ──► ended
```
Hooks are authoritative when present. Otherwise the JSONL heuristic applies: a last line of `assistant` with `tool_use` means running, a last line of `assistant` with an end turn means idle, and no writes for 10 min means idle.

## 5. Pricing engine
- A bundled `prices.json` (per model: input, output, cache write 5m and 1h, cache read) keyed by model id, with prefix matching for dated variants.
- An optional weekly refresh from LiteLLM's public `model_prices_and_context_window.json`; the user can override any price.
- Local models (Ollama) cost $0 but still show tok/s.
- Cost is computed at ingest and stored, so later price changes don't rewrite history.

## 6. Storage
SQLite tables `usage(request_id PK, …)`, `sessions`, `state_changes`. On first launch it backfills the last 30 days from JSONL. Byte offsets are checkpointed per file so restarts resume where they left off.

## 7. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | SPM scaffold, `MenuBarExtra` with a static label, GitHub Actions build | the app runs from Xcode and CI is green |
| M1 | Claude JSONL adapter, pricing, SQLite, "$ today" in the menu bar | totals match `ccusage` within 1% on real logs |
| M2 | Unix socket, `agentglance emit`, `install-hooks` (shows a diff of `~/.claude/settings.json` and asks consent), live state per session, notifications | state flips under 1 s after a hook fires |
| M3 | Panel UI: session list, Swift Charts sparkline, budget bar, launch at login (`SMAppService`) | usable daily |
| M4 | Codex and Gemini (OTLP) adapters | fixture tests pass |
| M5 | Ollama proxy and `/api/ps`; `agentglance run` PTY wrapper | true tok/s for Ollama |
| M6 | Developer ID signing, notarization, Homebrew cask, Sparkle updates | `brew install --cask agentglance` |

## 8. Non-goals and constraints
- No App Store: the app needs to read `~/.claude`, `~/.codex` and similar folders without the sandbox, so it ships as a notarized Developer ID build.
- It never reads or stores prompt or response text, only usage fields.
- It never edits agent config silently. Hook install is explicit and reversible (`uninstall-hooks`).

## 9. Open questions
1. Should the menu bar show spend for today or for the current billing month by default?
2. Subscription users (Claude Max/Pro) don't pay per token. Should they get an "API-equivalent cost" label and a plan-usage view instead?
3. Should there be a team mode later (an optional push to a shared endpoint), or stay strictly local?
