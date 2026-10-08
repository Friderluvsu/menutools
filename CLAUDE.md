@AGENTS.md

# Claude Code Notes

Shared project rules are imported above from AGENTS.md. The rules below apply only to Claude Code sessions.

## Build & Run
- Build only through make targets: `make build`, `make release`, `make run`, `make preview`. Raw `swift build` skips the settings in `scripts/build.sh`: the pinned SDK, the module-cache path, `--disable-sandbox` and the Swift compatibility flag. The compatibility flag is needed when the Swift compiler and macOS SDK versions differ, which `make doctor` checks, so raw `swift build` can fail on that mismatch. It also never produces the signed bundle that the Accessibility grants are tied to.
- Never execute `.build/...` binaries. Run the bundle at `build/MenuTools.app` (through `make run` or `open`).
- `make preview` runs `killall MenuTools` first, so it closes the user's running app. It also replaces `build/MenuTools.app` with a debug build. Warn the user before running it. Afterwards `make run` rebuilds the release bundle.
- Run one build at a time. `make build`, `make release` and `make preview` all write to `build/` and `.build/`.

## Verifying UI
- Run `make preview`, then read `build/preview-dashboard.png`, `build/preview-settings.png` and `build/preview-anti-sleep.png` with the Read tool.
- A PNG shows the layout only. Resizing, drag-and-drop, focus and click behaviour of the live panel need a manual check with `make run`.

## Credentials
- Never read Keychain items or token files, and never print token values. That covers `security find-generic-password -w`, `~/.claude/.credentials.json`, `~/.codex/auth.json` and the agy token file.
- Diagnostics print statuses only. Do not extend them to print secrets.
- Do not run `--ai-limits-diagnose` unless the user asks. It reads the Keychain secret inside the process, even though it prints only statuses.
- Do not copy account details (plan names, usage numbers, email addresses) into documentation or code.

## Subagent Model Routing
- **Haiku 5.5**: documentation, mechanical edits, build and measurement runs.
- **Sonnet 5.5**: feature implementation, research and audits.
- **Opus**: cross-cutting integration, AppKit state machines (panel, drag, status item) and adversarial review.
- Split large requests by these tiers. Give each agent disjoint files, and run one build at a time. Update the docs after changes.
