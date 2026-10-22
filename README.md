# AgentGlance

A lightweight macOS menu bar app that shows, at a glance, how close you are to your AI plan limits (Claude's 5-hour and weekly windows) and what your agents are doing (`running`, `awaiting_input`, `idle`), with live tokens/second.

```
5h 23% · 7d 41% · ● 2 running · 1 waiting
```

No more switching to terminal windows to check whether an agent is stuck waiting for you, or finding out mid-task that you've hit your limit.

> Status: planning. See [docs/PLAN.md](docs/PLAN.md).

## Planned sources

| Source | How it's observed |
|---|---|
| Claude Code | Status line bridge for 5h/7d limits; tails `~/.claude/projects/**/*.jsonl` for tokens; hooks push state over a Unix socket |
| Codex CLI | Tails `~/.codex/sessions/**/rollout-*.jsonl` |
| Gemini CLI | OpenTelemetry (OTLP) receiver |
| Ollama | Opt-in local proxy plus `/api/ps` polling |
| Anything else | `agentglance run -- <cmd>` PTY wrapper |

Everything stays local. AgentGlance reads only usage and limit metadata, never prompt content, and sends nothing off the machine.
