# AgentGlance

**Activity Monitor for AI agents.** See what Claude Code, Codex and Gemini CLI started on your Mac (dev servers, MCP servers, watchers, sub-agents), and switch it off when they're done.

```
● claude  login-page (e77adda0)     running · 3 procs · 412 MB
○ claude  fix-tests  (9b1c22aa)     ENDED · left 2 procs · 1.2 GB
      48211  node   :3000   812 MB
      48230  esbuild        390 MB
```

## Why
Agents leave background processes running after a session ends. Activity Monitor can't tell which `node` belongs to which agent, so you can't clean up safely. AgentGlance tracks **ownership**: each process is tied to the agent session that started it, even after the agent exits.

## Use
```bash
swift build -c release
.build/release/agentglance ps            # who started what
.build/release/agentglance clean --dry-run
.build/release/agentglance clean         # stop everything ended sessions left behind
./scripts/bundle.sh && open build/AgentGlance.app   # menu bar app
./scripts/test.sh                        # tests
```

## How it knows who started what
1. **Live ancestry:** the process descends from a running `claude`, `codex` or `gemini`.
2. **Inherited tag:** Claude Code stamps `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` into every process it spawns, so leftovers stay traceable after Claude exits.
3. **Ledger memory:** ownership is remembered as `(pid, start time) → session`, so other agents' leftovers stay traceable too, and a reused PID is never confused with an old process.

Cleanup only touches processes from **ended** sessions (or single PIDs you name), re-checks each process's identity before signalling it, and sends SIGTERM, then SIGKILL after 3 s.

See [docs/PLAN.md](docs/PLAN.md) for the design, the safety rules and the roadmap. Everything stays local.
