# Session tokens and cost

Source: `Sources/MenuTools/Features/AgentUsage/` (`SessionUsage`, `ClaudeTranscriptUsage`, `CodexRolloutUsage`), shown by `Views/Components/AgentSessionRows.swift`.

Each session row carries a small badge before the uptime, and the details drawer gets Tokens / In-out / Cache / Cost / Model / Context rows. Everything is read from the agent's own files on disk; no network call and no token is read. Antigravity logs no token data, so its rows show nothing.

| Provider | Source | Badge | Drawer rows |
|---|---|---|---|
| Claude Code | `projects/<cwd as dashes>/<sessionId>.jsonl` and `<sessionId>/subagents/*.jsonl` under `$CLAUDE_CONFIG_DIR` (or `~/.claude`) | `~$4.12` (estimate at public API rates) | Tokens, In / out, Cache, Cost, Model, Context |
| Codex | `threads.rollout_path` in `~/.codex/state_*.sqlite` → the last `token_count` event in that rollout | `18k tok` | Tokens, In / out, Cache, Model, Context (of the model window) |
| Cursor | `composerData:<id>` → `contextTokensUsed`, `contextTokenLimit` | `11% ctx` | Context |

## Claude

Every assistant line in a transcript carries `message.usage` (`input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, and `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`) and `message.model`. Claude writes one line per content block with the same `message.id` and the same usage, so each id is counted once (`seen` set per session). Lines without both `"usage"` and `"assistant"` bytes are skipped before any JSON decode.

Files are append-only. `ClaudeTranscriptUsage` keeps a byte offset per file and reads only what was added since the last tick, in 4 MB chunks, carrying a partial last line. The first pass reads the whole file (a 60 MB transcript takes well under a second on the utility queue). A file that shrank is re-read from the start. The reader runs on its own detached task started after each background refresh has applied the session list (`refreshUsage`, one at a time), never on the synchronous launch / panel-open read, so a first pass over a large transcript never delays a status change or a "needs input" notification, and the first numbers appear one tick (2 s) after the panel opens. `ClaudeSessionsManager.usage` is published only when a value changed.

The transcript folder is guessed from the cwd (every character other than a letter or digit becomes `-`), then the older `/` → `-` form, then the whole `projects` folder is scanned for `<sessionId>.jsonl`. A miss is retried after 10 s. The subagents folder is listed every 2 s.

**Context** is the last main-transcript request's `input + cache read + cache write`, i.e. what the next turn will carry. Sidechain lines are excluded from it but counted in the totals.

**Cost** is an estimate at the public API list prices in `ClaudePricing` (USD per MTok; cache writes 1.25× input for the 5-minute TTL and 2× for the 1-hour TTL, both known per message from `cache_creation`):

| Family | Input | Output | Cache read |
|---|---|---|---|
| Fable / Mythos 5.1+ | 10 | 50 | 0.25 |
| Fable / Mythos 5 | 10 | 50 | 1.00 |
| Opus 5.5+ | 4 | 20 | 0.20 |
| Opus 4.5 – 5 | 5 | 25 | 0.50 |
| Opus 4 – 4.1 | 15 | 75 | 1.50 |
| Sonnet 5+ | 2 | 10 | 0.20 |
| Sonnet ≤ 4.6 | 3 | 15 | 0.30 |
| Haiku 5.5+ | 0.10 | 0.50 | 0.01 |
| Haiku 4.5 | 1 | 5 | 0.10 |
| Haiku 3.5 | 0.80 | 4 | 0.08 |
| Haiku 3 | 0.25 | 1.25 | 0.03 |

The model id is parsed by family word and the one or two numbers after it (or before it for `claude-3-5-haiku`). A turn whose model has no price adds to `unpricedTurns`, and the cost shows a trailing `+`. `<synthetic>` messages have no usage. A subscription user pays nothing per token; the number says what the same work costs at API rates (the way `ccusage` reports it).

## Codex

`threads` in the newest `state_*.sqlite` has `rollout_path`. The rollout's `event_msg` / `token_count` events carry `info.total_token_usage` (cumulative for the thread: `input_tokens` includes `cached_input_tokens`; `output_tokens` includes reasoning), `info.last_token_usage` and `info.model_context_window`. Only the last 256 KB of the file is read, only when its size changed, and at most every 5 s per file (cache keyed by path), because the Codex poll runs synchronously on the main actor and the log grows throughout a turn. Token changes alone do not rewrite the watch file: `CodexFact.sameChat` compares everything but the usage, and the in-memory usage is saved with the next real change or when the process ends. The model name comes from the latest `turn_context` event in that tail, when one is there. No price table for OpenAI models, so no cost. The usage at exit is stored with the Ended row (`CodexFact.usage` → `CodexEndedSession.usage` in `codex-session-watch.json`; older files decode with it nil).

## Cursor

`composerGeneration` already json_extracts a few fields from `composerData:<id>` for recent headers; `contextTokensUsed` and `contextTokenLimit` are two more columns in that query. Cursor logs no per-turn spend in the header or composer data (`usageData` is empty), so only context fill is shown. Ended rows do not carry it.

## Formatting

`TokenFormat.short`: 950, 1.2k, 12k, 1.2M. `TokenFormat.cost`: `~$0.04`, `~$4.12`, `~$41.5`, `~$120`. The badge picks cost, then tokens, then context fill. `SessionUsage.detailLines` builds the drawer rows and leaves out whatever is unknown.

## Preview

`--render-preview --sessions --open-session-detail claude:83592` shows the Claude sample with usage; `codex:4242` and the Codex Ended sample carry `SessionUsage.codexSample`; the first Cursor sample carries a context fill.
