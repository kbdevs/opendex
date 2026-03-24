# AGENTS.md (Local-First)

Keep this in sync with `CLAUDE.md`. Agents run entirely on the user’s Mac—no hosted relays by default, no remote CI, no production credentials. Prefer local bridge + QR pairing over any cloud shortcut.

## 1. Mindset & Guardrails

1. Stay intraprendente: inspect code/docs before asking, default to concise answers unless detail is requested.
2. Maintain repo isolation by `cwd`; do not assume sidebar filters or multi-repo tooling exist.
3. Preserve trusted reconnect flows. Never clear saved relay info unless asked, and keep timeline rows scoped so UI order stays stable.
4. Treat the project as OSS-quality: avoid placeholder hacks, noisy debug prints, or scratch Markdown files in repo root unless explicitly requested.
5. Redact relay secrets, `sessionId`, QR payloads when logging. Use `[remodex] ...` or `[relay] ...` single-line logs.
6. Cursor/Copilot rules: none exist (`.cursor/` missing, `.github/copilot-instructions.md` absent). This doc + `CLAUDE.md` define behavior.

## 2. Repository Layout

1. `phodex-bridge/`: Node 18+ CLI (“remodex”), CommonJS, plain JS, published to npm.
2. `relay/`: Minimal Node WebSocket relay used by `./run-local-remodex.sh` and manual testing.
3. `CodexMobile/`: SwiftUI iOS app (`CodexMobile.xcodeproj`, iOS 18.6 target, no CocoaPods/SPM deps).
4. `Docs/`, `SELF_HOSTING_MODEL.md`, `CONTRIBUTING.md`: update alongside behavior changes.
5. `run-local-remodex.sh`: local launcher wiring Codex CLI + relay + bridge.

## 3. Toolchain

- Node.js 18+ (Bun 1.1+ acceptable for `bun install`, scripts still call `node`).
- Codex CLI (`codex app-server`) installed and available on PATH.
- Xcode 16+ for Swift build/test; simulator or device for UI verification.
- macOS strongly preferred; Linux/Windows limited to foreground bridge.
- Secrets/API keys live in ENV/`~/.env`; never hardcode values in code or docs.

## 4. Build / Lint / Test Commands

### Bridge (`phodex-bridge`)

- Install deps: `cd phodex-bridge && bun install` (or `npm install`).
- Launch with custom relay: `REMODEX_RELAY="ws://localhost:9000/relay" npm start`.
- All tests: `npm test` → `node --test ./test/*.test.js`.
- Single test file: `node --test test/session-state.test.js`.
- Single test name: `node --test test/session-state.test.js --test-name-pattern "resume trusted session"`.
- Debug: `NODE_OPTIONS="--inspect" node --test test/session-state.test.js`.

### Relay

- Install deps: `cd relay && bun install`.
- Start server: `node server.js`.
- All tests: `npm test` (`node --test ./*.test.js`).
- Single test: `node --test relay-handshake.test.js --test-name-pattern handshake`.

### Swift (CodexMobile)

- Open project: `cd CodexMobile && open CodexMobile.xcodeproj`.
- Build (simulator): `xcodebuild -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' build`.
- Run tests: `xcodebuild test -scheme CodexMobile -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2'`.
- Only specific suite: append `-only-testing CodexMobileTests/CodexServiceTests` (or other class).
- UI tests (slow): `xcodebuild test -scheme CodexMobileUITests -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2'`.

### Linting/Formatting

- No enforced JS/Swift lint tool. Match existing style. Shell scripts must keep `#!/usr/bin/env bash` + `set -euo pipefail`.
- Bun is only for dependency installs; keep execution under `npm run` to match published CLI.

## 5. Common Commands

| Goal | Command |
| --- | --- |
| Launch local stack | `./run-local-remodex.sh [--hostname <lan>] [--bind-host 127.0.0.1 --port 9100]` |
| Bridge only | `cd phodex-bridge && REMODEX_RELAY="ws://localhost:9000/relay" npm start` |
| Relay standalone | `cd relay && node server.js` |
| Check daemon | `remodex status` (macOS) |
| Stop daemon | `remodex stop` |
| Reset pairing | `remodex reset-pairing` |
| Package for npm | `cd phodex-bridge && npm pack` |

## 6. Debugging & Diagnostics

1. Bridge logs already show connection states; temporary verbose logs must sit behind env flags (e.g., `DEBUG_RELAY`).
2. Device state persists in `~/.remodex/device-state.json`; never commit or paste contents. Describe the issue instead.
3. Threads live in `~/.codex/sessions`. Use `createRolloutLiveMirrorController` rather than hand-rolling file watchers.
4. Remote Codex endpoints require explicit `REMODEX_CODEX_ENDPOINT`. Explain overrides in PR/test plans.
5. Push/relay configuration changes must update README + SELF_HOSTING_MODEL.md.

## 7. JavaScript Code Style

1. CommonJS modules only. Import order: Node built-ins → third-party → local modules grouped by concern.
2. Prefer `const`; use `let` only when reassignment is required. No `var`.
3. Functions should be pure where possible. Pass dependencies explicitly to helpers (`handleDesktopRequest(..., { bundleId })`).
4. Startup failures call `console.error` and `process.exit(1)` with actionable remediation steps.
5. Long-lived sockets/backoffs follow the `scheduleRelayReconnect` capped retry pattern; mirror it in new transports.
6. Logging stays `[remodex] message` or `[relay] message`. Avoid stack traces unless diagnosing failures.
7. Optional OS-specific features must fail loudly (clear instructions when AppleScript refresh/push service missing).
8. File headers follow `// FILE:`, `// Purpose:`, `// Layer:`. Update when renaming/moving files.
9. Tests rely on `node:test` + `node:assert/strict` with descriptive names tied to behavior.

## 8. Swift Code Style

1. SwiftUI + Swift Concurrency. Mark services touching UI state as `@MainActor` or `@Observable`.
2. Use `struct` + `Sendable` for data types; keep computed props pure.
3. Enums remain exhaustive—avoid string literals for state checks.
4. Group properties logically: public state → derived caches → private wiring → test hooks. Maintain four-space indentation.
5. File headers mirror JS convention and describe dependencies.
6. Extend `CodexService` through focused `CodexService+Feature.swift` files to keep main file readable.
7. Error handling flows through domain types (`CodexServiceError`). Surface issues via banners/prompts, not `print`.
8. Networking via `NWConnection`/`URLSessionWebSocketTask` resolves continuations exactly once; guard against double-resume.
9. Persistence writes remain debounced; avoid synchronous disk I/O on the main actor.

## 9. Naming, Imports, Config

- JS imports alphabetical within group; relative paths start with `./`.
- Swift imports ordered Foundation → Apple frameworks → local modules.
- Config/environment keys use uppercase snake case (`REMODEX_RELAY`, `REMODEX_REFRESH_ENABLED`). Document new keys.
- Naming stays descriptive (`createPushNotificationTracker`, `CodexDesktopRefresher`) rather than terse abbreviations.

## 10. Error Handling Expectations

1. CLI commands exit fast when core config missing (relay URL, unreadable device state) and mention remediation.
2. Sockets swallow transient errors but bail on fatal close codes (4000/4001). Keep semantics aligned with existing behavior.
3. Swift networking surfaces errors through `CodexConnectionRecoveryState` and UI prompts; no silent catches.
4. Git handler responses redact commit contents in logs and return structured JSON to the phone.

## 11. Docs & Communication

1. Update README/SELF_HOSTING_MODEL.md when behavior or config changes.
2. Keep `AGENTS.md` and `CLAUDE.md` synchronized. New guardrails belong in both.
3. Markdown stays ASCII unless file already uses non-ASCII glyphs.
4. Avoid adding new root-level reports; keep ad-hoc analysis in chat or PR comments.

## 12. Build/Test Discipline

- Respect build guardrail: run heavy Xcode suites only when necessary or requested. Prefer targeted Swift unit tests.
- For JS changes, run `npm test` in affected package; CI via `.github/workflows/bridge-check.yml` covers the rest.
- Summaries of command output should mention pass/fail and key lines, not entire log dumps.

## 13. Git Hygiene

1. Never reset or amend user commits unless explicitly instructed.
2. Treat Git RPCs from the phone as canonical; CLI handlers must mimic them (see `phodex-bridge/src/git-handler.js`).
3. `run-local-remodex.sh` leaves relay/bridge running—stop background processes post-test to avoid port conflicts.

## 14. Support Matrix

- macOS: daemon, desktop refresh, QR pairing persistence, push preview, AppleScript bounce all supported.
- Linux/Windows: bridge works foreground-only; document limitations when touching cross-platform surfaces.
- iOS app requires manual install; mention this whenever onboarding flows change.

## 15. Troubleshooting Checklist

1. Bridge fails to start → ensure `REMODEX_RELAY` provided and Codex CLI installed.
2. Relay disconnect loops → inspect `scheduleRelayReconnect` logic and relay logs for fatal codes.
3. iOS timeline glitches → verify `ThreadTimelineState` invariants and `activeTurnIdByThread` updates.
4. Git commands missing → update `git-handler.js` plus iOS RPC schema together; document new endpoints.
5. Docs drift → re-read README + SELF_HOSTING_MODEL.md before finalizing PR.

---

Favor local-first workflows, trusted reconnect UX, and minimal dependencies. When unsure, revisit this file and `CLAUDE.md` before landing changes.
