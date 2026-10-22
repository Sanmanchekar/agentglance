# AgentGlance

A lightweight macOS menu bar app that shows, at a glance, what your AI coding agents and local LLMs are doing: their state (`running`, `awaiting_input`, `idle`), live tokens/second, and total API spend.

No more switching to terminal windows to check whether an agent is stuck waiting for you or burning through tokens.

> Status: planning. See [docs/PLAN.md](docs/PLAN.md).

## Planned sources

| Source | How it's observed |
|---|---|
| Claude Code | Tails `~/.claude/projects/**/*.jsonl` for usage; hooks push state over a Unix socket |
| Codex CLI | Tails `~/.codex/sessions/**/rollout-*.jsonl` |
| Gemini CLI | OpenTelemetry (OTLP) receiver |
| Ollama | Opt-in local proxy plus `/api/ps` polling |
| Anything else | `agentglance run -- <cmd>` PTY wrapper |

Everything stays local. AgentGlance reads only usage metadata, never prompt content, and sends nothing off the machine.
