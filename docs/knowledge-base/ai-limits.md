# AI Limits

Source: `Sources/MenuTools/Features/AILimits/` (`AILimitsManager`, `AIUsageFetchers`, `AILimitsCache`, `AILimitsModels`) and `Views/Components/AILimitsCard.swift`.

Everything is read-only and needs no extra login. MenuTools never refreshes or writes a provider's token. Claude Code, Codex and Antigravity use undocumented internal APIs, so every response field is optional. Cursor is read from the `agent` CLI only.

## Sources at a glance

| Provider | Credentials read | Request | Fallback |
|---|---|---|---|
| Claude Code | Keychain item `Claude Code…credentials` (secret read via `/usr/bin/security`) or `$CLAUDE_CONFIG_DIR/.credentials.json` / `~/.claude/.credentials.json` | `GET https://api.anthropic.com/api/oauth/usage` | none; expired token shows "Login expired" |
| Codex | `$CODEX_HOME/auth.json` or `~/.codex/auth.json` (`tokens.access_token`, `tokens.account_id`) | `GET https://chatgpt.com/backend-api/wham/usage` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (last 7 days) |
| Antigravity | IDE language server (process arguments) or agy CLI token | local RPC, then `cloudcode-pa.googleapis.com` | agy CLI token; expired token → `agy -p /usage` |
| Cursor | Cursor CLI login | `agent about --format json`, with the CLI's own client also reading period usage | none |

## Claude Code

**Token discovery.** `SecItemCopyMatching` with attributes only (no secret, no prompt) finds generic-password services whose name starts with `Claude Code` and contains `credentials`. Newest modification first. A `CLAUDE_CONFIG_DIR` setup adds a hash suffix (`Claude Code-credentials-<hash>`). The secret is then read by running `/usr/bin/security find-generic-password -s <service> -w`, which avoids an extra Keychain prompt.

**Credential JSON.** `claudeAiOauth`: `accessToken`, `expiresAt` (epoch milliseconds), `subscriptionType`, `rateLimitTier`.

**Expiry.** Expired means `expiresAt` is less than 30 s away. Then no request is sent and the result is `Login expired — run claude`. An `ExpiredGate` remembers the Keychain item modification stamps for 30 min, so repeated refreshes do not re-read the Keychain. The gate clears when Claude Code rewrites the item. It is skipped when a credentials file exists.

**Request.**
- `Authorization: Bearer <token>`
- `anthropic-beta: oauth-2025-04-20`
- `Accept: application/json`
- `User-Agent: claude-code/2.1.0`
- timeout 15 s

**Response fields.**
- `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`: objects with `utilization` (0–100, divided by 100 in code) and `resets_at` (ISO-8601).
- `limits[]`: entries with `kind == "weekly_scoped"`, `percent`, `resets_at`, `scope.model.display_name`. When present these replace the `seven_day_*` fields.
- Enterprise / Team seats often have those windows as `null`. The same payload still has:
  - a dollar pool object (obfuscated key) with `utilization`, `limit_dollars` / `used_dollars`, `resets_at` → **Included**
  - `extra_usage` (`is_enabled`, `monthly_limit` and `used_credits` in cents, `utilization`) and `spend` (`enabled`, `percent`, `used` / `limit` with `amount_minor`) → **Spend**, only when extra usage is on and a limit is set. Spend has no reset time in this API.

`claude /usage` is TUI-only (`-p` is not available). Do not spawn it; the OAuth endpoint is the source.

**Labels.** `Session` (five-hour), `Week`, then either `Week Opus` / `Week Sonnet` or `Week <model name>`. Enterprise adds `Included` and `Spend` when the consumer windows are empty (or alongside them when usage credits are on).

**Plan.** `rateLimitTier` containing `max_20x` → `MAX 20×`; `max_5x` → `MAX 5×`; otherwise `subscriptionType` in uppercase.

## Codex

**Online.** `auth.json` → `Authorization: Bearer <access_token>`, `Accept: application/json`, `User-Agent: MenuTools`, and `ChatGPT-Account-Id` when `account_id` is present. Timeout 15 s.

Response: `plan_type`; `rate_limit.primary_window` and `rate_limit.secondary_window`, each with `used_percent`, `limit_window_seconds`, `reset_at` (epoch seconds) or `reset_after_seconds`.

**Offline fallback.** Reads the newest `rollout-*.jsonl` files from the last 7 days. It scans each file backwards for the latest `event_msg` line whose `payload.type == "token_count"` and has `payload.rate_limits`. Fields: `primary` and `secondary`, each with `used_percent`, `window_minutes`, `resets_at` or `resets_in_seconds`, plus `plan_type`. Windows whose reset has passed are shown as 0% with no reset time. The result is stamped with the log time, so it is marked stale after 15 min.

**Combination.** Online `ok` wins. Otherwise the rollout fallback is used, and a 429 back-off from the online call is kept.

**Labels.** 300 min → `5h`; 10080 min → `Week`; otherwise days, hours or minutes, or `Limit` when unknown.

## Antigravity

**Local (IDE open).**
1. `/bin/ps -ax -o pid=,command=` finds a `language_server*` command line that mentions `antigravity` and has `--csrf_token`. It also reads `--extension_server_port` and `--extension_server_csrf_token`.
2. `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -a -p <pid> -Fn` lists the listening ports.
3. Each `https://127.0.0.1:<port>` is tried with the CSRF token. The HTTP extension server (`http://127.0.0.1:<port>`) is the fallback. `LocalhostSession` accepts the self-signed certificate only for `127.0.0.1` and `localhost`.
4. Calls are `POST /exa.language_server_pb.LanguageServerService/GetUserStatus` (metadata body) and then `RetrieveUserQuotaSummary` with `forceRefresh: true`.
5. Headers: `Content-Type: application/json`, `Connect-Protocol-Version: 1`, `X-Codeium-Csrf-Token`. Timeout 6 s.

Parsing: `groups[]` with `displayName` and `buckets[]` (`remainingFraction` or `remaining.remainingFraction`, `resetTime`, `window` / `bucketId`, `disabled`). Legacy fallback: `GetUserStatus.userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo`, keeping the most constrained model per pool. Labels look like `Gemini Wk`, `Gemini 5h`, `Claude/GPT Wk`. Plan comes from `userTier.name` or `planInfo`, with `Google AI ` removed.

**CLI (IDE closed).**
1. Keychain `security find-generic-password -s gemini -a antigravity -w`. The value is a Go keyring blob: plain JSON, `go-keyring-base64:` (base64) or `go-keyring-encoded:` (hex). Inside: `token.access_token`, and `token.expiry` or `token.expiry_date` (ms).
2. File fallback: `$ANTIGRAVITY_CONFIG_DIR/antigravity-oauth-token`, else `~/.gemini/antigravity-cli/antigravity-oauth-token`.
3. A token is fresh if it expires more than 60 s from now. A fresh token is sent to cloud:
   - `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` (fallback host `daily-cloudcode-pa.googleapis.com`). Body metadata: `ideType: ANTIGRAVITY`, `platform`, `pluginType: GEMINI`.
   - Then `:retrieveUserQuotaSummary` with `project` (from `cloudaicompanionProject`). If that fails, `:fetchAvailableModels` (the `models` map, skipping `isInternal`).
   - Headers: `Authorization: Bearer <token>`, `Content-Type: application/json`, `User-Agent: antigravity/hub/2.9.1 darwin/arm64`. Timeout 10 s.
4. A stale token runs `agy -p /usage --output-format json` (90 s timeout, run in the temp directory). agy refreshes its own token. MenuTools then re-reads the token and calls cloud again, or parses agy's JSON output.
5. agy is looked up at `~/.local/bin/agy`, `/opt/homebrew/bin/agy`, `/usr/local/bin/agy`.

## Cursor

MenuTools does not call Cursor's HTTP APIs and does not read `state.vscdb`. It runs the Cursor CLI: explicit arguments, no shell, timeout 25 s, from the temp directory.

The binary is the first executable of `~/.local/bin/agent`, `/opt/homebrew/bin/agent`, `/usr/local/bin/agent`. A missing binary is `Install the Cursor CLI`.

`agent about --format json` is the only scriptable account command. On its own it returns `subscriptionTier` and an email. MenuTools loads `Resources/cursor-usage-hook.js` with `NODE_OPTIONS=--require` and `NODE_DISABLE_COMPILE_CACHE=1`. The hook runs inside that CLI process and asks the CLI's own dashboard client for the same period usage as the interactive `/usage` command (`getCurrentPeriodUsage`). It adds a `usage` object to the JSON and replaces the email with null before anything is printed.

`subscriptionTier` is the plan: `pro` → `PRO`, `pro_plus` / `pro+` → `PRO+`, `ultra` → `ULTRA`, `free` / `hobby` → `FREE`, `business` / `team` → `TEAM`, anything else uppercased. No plan is `Login expired — run agent login`. **Run** opens Terminal on `agent login`.

`usage` fields, each 0–100: `totalPercentUsed` → **Included**, `autoPercentUsed` → **Auto**, `apiPercentUsed` → **API**, `onDemandPercentUsed` → **On-demand** (omitted when there is no spend cap). The card shows the two fullest. `billingCycleEnd` is unix milliseconds and is the reset for every window. A missing `usage` object, or `usage.error`, is `Couldn't read Cursor usage`. The hook matches this CLI build's `about` command text; a CLI update that rewrites that text fails the same way until the hook is updated.

## Cache, stale and rollover

File: `~/Library/Application Support/MenuTools/ai-limits-cache.json` (version 1, one entry per provider: `plan`, `windows`, `fetchedAt`, `blockedUntil`). Written off the main thread, atomically.

- Loaded at launch. Cached windows appear immediately as stale.
- A successful fetch replaces the entry and clears the stale flag.
- A failed fetch keeps the last windows, marked stale, with the failure text as `note` (for example `Login expired — run claude`). The card shows the numbers dimmed, `cached Xh ago` and the note. The tooltip lists every window.
- A failed fetch with no cached windows shows the failure as a row with a Run button if it is a login problem.
- `rolledOver(now:)`: any window with `resetsAt <= now` is shown as 0%, reset unknown. The card uses one 30 s `TimelineView`, so countdowns and rollover update without polling.
- Data whose `fetchedAt` is more than 15 min old is marked stale.

## Timing

| Constant | Value | Meaning |
|---|---|---|
| `staleInterval` | 120 s | Panel open re-fetches a provider only if its last attempt is older. |
| `backgroundInterval` | 300 s, tolerance 30 s | Timer while the panel is open. Stopped on close. |
| `minimumGap` | 10 s | Refresh button: at most one attempt per provider. |
| `staleAfter` | 900 s | Data older than this is marked stale. |
| soft back-off | 60 s × 2^(n−1), max 900 s | After a failure. Background polls skip the provider. The refresh button ignores it. |
| 429 back-off | `Retry-After` clamped to 60 s…1 h; with no header, 300 s × 2^(n−1), max 1 h | Hard block, persisted in the cache file. Never bypassed. |

`AILimitsManager.startMonitoring()` runs from `AppState.onPopoverWillShow` and `stopMonitoring()` from `onPopoverDidClose`.

## Status strings and failure modes

| Status text | Provider | Cause | What to do |
|---|---|---|---|
| `Login expired — run claude` | Claude | token expired (locally or HTTP 401) | Run button opens Terminal on `claude` |
| `Token lacks usage scope` | Claude | HTTP 403 | sign in again with `claude` |
| `Rate limited, retry later` | Claude, Codex | HTTP 429 | wait; the card shows `Rate limited — retry in …` when there is no cache |
| `Login expired — run codex` | Codex | HTTP 401 | Run button opens Terminal on `codex login` |
| `HTTP <code>` | any | other status | check the provider |
| `Offline`, `Timed out`, `Network error`, `Unexpected response` | any | `URLError` / decoding | retried on the next refresh |
| `Login expired — run agy` | Antigravity | token expired and agy missing or failed | Run button opens Terminal on `agy` |
| `Quota API unavailable` | Antigravity | cloud call failed | retry later |
| `Language server port not found` / `Language server did not respond` | Antigravity | IDE running but its RPC is unreachable | the CLI path is tried next |
| `Open Antigravity or sign in with agy` | Antigravity | neither IDE nor CLI token found | not connected |
| `Not connected` (`notConnected`) | Claude / Codex | no credentials file or Keychain item | sign in with the CLI |
| `Install the Cursor CLI` | Cursor | `agent` not found on the known paths | install the CLI |
| `Login expired — run agent login` | Cursor | `agent about` returned no plan | Run button opens Terminal on `agent login` |
| `Couldn't read Cursor usage` | Cursor | `agent about` failed, or the usage hook did not return percents | retry; the CLI needs a network connection. A CLI update can also break the hook |

The Run button (`openLoginTerminal`) writes a temp `.command` file, opens it in Terminal, and clears the back-off so the next panel open retries right away.

## Diagnostics

`MenuTools --ai-limits-diagnose` prints one line per check: Keychain scan result, service names, token presence and expiry in minutes, IDE running, agy path, whether the Cursor CLI is installed (no email), per-provider status and windows, and cache age. No token or secret is printed, but the Keychain secret is read in-process for Claude and Antigravity. Run it only when the user asks.
