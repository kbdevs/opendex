<p align="center">
  <img src="CodexMobile/CodexMobile/Assets.xcassets/remodex-og.imageset/remodex-og2%20(1).png" alt="Opendex" />
</p>

# Opendex

[![npm version](https://img.shields.io/npm/v/opendex)](https://www.npmjs.com/package/opendex)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[Follow on X](https://x.com/emanueledpt)

Control OpenCode from your iPhone. Opendex is a local-first open-source bridge + iOS app that keeps the OpenCode runtime on your Mac and lets your phone connect through a paired secure session.

## Key App Features

- End-to-end encrypted pairing and chats between your iPhone and Mac
- Fast mode for lower-latency turns
- Plan mode for structured planning before execution
- Subagents from iPhone with the `/subagents` command
- Steer active runs without starting over
- Queue follow-up prompts while a turn is still running
- In-app notifications when turns finish or need attention
- Git actions from your phone, including commit, push, pull, and branch switching
- Reasoning controls to tune how much thinking OpenCode uses
- Access controls with On-Request or Full access
- Photo attachments from camera or library
- One-time QR bootstrap with trusted Mac reconnects
- macOS-only background bridge service via `launchd`
- Live streaming on your phone while OpenCode runs on your Mac
- Shared thread history with OpenCode on your Mac

The repo stays local-first and self-host friendly: the iOS app source does not embed a public hosted endpoint, and the transport layer remains inspectable for anyone who wants to run their own setup.

Today, the background daemon / trusted auto-reconnect flow is implemented for macOS. Self-hosted relay setups still work on other OSes, but they currently use the foreground bridge flow instead of the macOS `launchd` service path.

If you want the public-repo distribution model explained clearly, read [SELF_HOSTING_MODEL.md](SELF_HOSTING_MODEL.md).

> **I am very early in this project. Expect bugs.**
>
> I am not actively accepting contributions yet. If you still want to help, read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Get the App

Build the iOS app from source in Xcode, install your own signed build on-device, then use the in-app onboarding flow to pair by scanning the QR from `opendex up`.

If you scan the pairing QR with a generic camera or QR reader before installing the app, your device may treat the QR payload as plain text and open a web search instead of pairing.

## Architecture

```
┌──────────────┐       Paired session   ┌───────────────┐       stdin/stdout       ┌─────────────┐
│  Opendex iOS │ ◄────────────────────► │ opendex (Mac) │ ◄──────────────────────► │ OpenCode    │
│  app         │    WebSocket bridge    │ bridge        │    JSON-RPC shim         │ runtime     │
└──────────────┘                        └───────────────┘                          └─────────────┘
                                               │                                         │
                                               │  AppleScript route bounce                │ JSONL rollout
                                               ▼                                         ▼
                                        ┌─────────────┐                           ┌─────────────┐
                                         │  desktop app │ ◄─── reads from ──────── │ ~/.opencode/ │
                                        │  (desktop)  │      disk on navigate     │  sessions   │
                                        └─────────────┘                           └─────────────┘
```

1. Run `opendex up` on your Mac
2. On macOS, Opendex installs/starts a lightweight background bridge service and prints a QR for first-time pairing or recovery
3. Scan the QR once with the Opendex iOS app to trust that Mac
4. After the first handshake, the iPhone can resolve the Mac's live session through the configured relay and reconnect automatically
5. Your phone sends instructions to OpenCode through the bridge and receives responses in real-time
6. The bridge handles git operations and local session persistence on your Mac
7. The desktop app can read the same thread history from disk, but it is not a true live mirror unless you enable the optional refresh workaround

## Repository Structure

This repo contains the local bridge, the iOS app target, and their tests:

```
├── phodex-bridge/                # Node.js bridge package used by `opendex`
│   ├── bin/                      # CLI entrypoints
│   └── src/                      # Bridge runtime, git/workspace handlers, refresh helpers
├── CodexMobile/                     # Xcode project root (legacy folder name for now)
│   ├── CodexMobile/                 # App source target
│   │   ├── Services/             # Connection, sync, incoming-event, git, and persistence logic
│   │   ├── Views/                # SwiftUI screens and timeline/sidebar components
│   │   ├── Models/               # RPC, thread, message, and UI models
│   │   └── Assets.xcassets/      # App icons and UI assets
│   ├── CodexMobileTests/            # Unit tests
│   ├── CodexMobileUITests/          # UI tests
│   └── BuildSupport/             # Info.plist, xcconfig defaults, and local override templates
```

## Prerequisites

- **Node.js** v18+
- **OpenCode CLI** installed and in your PATH
- **OpenCode desktop app** (optional — for viewing threads on your Mac)
- **A signed Opendex iOS build** installed on your iPhone or iPad before scanning the pairing QR
- **macOS** (for desktop refresh features — the core bridge works on any OS)
- **Xcode 16+** (only if building the iOS app from source)

## Install the Bridge

<sub>Install from npm via Bun so you get the newest bridge fixes.</sub>

```sh
bun add -g opendex@latest
```

To update an existing global install later:

```sh
bun add -g opendex@latest
```

If you only want to try Opendex, you can install it globally and run it without cloning this repository.

## Quick Start

Install the bridge, then run:

```sh
opendex up
```

On first connect, open the Opendex app, follow the onboarding flow, then scan the QR code from inside the app.

After that first scan:

- the iPhone saves the Mac as a trusted device
- the Mac bridge keeps its identity locally
- the app tries trusted reconnect automatically on later launches
- the QR remains available as a recovery path if trust changes or the relay cannot resolve the live session

For now, the daemon-backed trusted reconnect path is macOS-only. If you self-host on Linux or Windows, pairing still works, but the bridge runs in the foreground unless you set up your own OS-specific service wrapper.

## Run Locally

```sh
git clone https://github.com/kbdevs/opendex.git
cd opendex
./run-local-opendex.sh
```

That launcher starts a local relay, points the bridge at `ws://<your-host>:9000/relay`, and prints the pairing QR for the iPhone app.

If you already have a stable relay that both the Mac and iPhone can reach (for example Tailscale or your own hosted `wss://` relay), you can use the same launcher without falling back to LAN-only routing:

```sh
./run-local-opendex.sh --relay-url "wss://relay.example.com/relay"
```

Or export it once before starting the bridge:

```sh
OPENDEX_RELAY="wss://relay.example.com/relay" ./run-local-opendex.sh
```

When you pair against a stable relay like that, the QR is only needed for the initial trust bootstrap. Later bridge restarts can reuse the saved relay config and the iPhone can reconnect through trusted-session resolve without scanning a fresh QR.

For iPhone self-hosting, the recommended path is Tailscale or another stable private network. Plain LAN pairing over `ws://<lan-ip>` on the same Wi-Fi is still available for local testing, but it can be unreliable on some iOS devices even when the relay and Wi-Fi are healthy.

Options:

- `./run-local-opendex.sh --hostname <lan-hostname-or-ip>`
- `./run-local-opendex.sh --bind-host 127.0.0.1 --port 9100`

If your iPhone is pairing over LAN, use a hostname or IP the phone can actually reach.

## Custom Relay Endpoint

For a full public self-hosting walkthrough, see [`Docs/self-hosting.md`](Docs/self-hosting.md).

If you want the npm bridge to point at your own setup instead of the package default, override `OPENDEX_RELAY` explicitly:

```sh
OPENDEX_RELAY="ws://localhost:9000/relay" opendex up
```

For self-hosted iPhone usage, prefer a relay URL reachable over Tailscale or another stable private network. Treat plain local `ws://192.168.x.x` pairing as best-effort rather than the recommended production path on iOS.

In a source checkout, `opendex up` now reuses the last saved daemon relay config when one exists, so after the first successful `OPENDEX_RELAY=... opendex up` you do not need to keep re-exporting the same relay just to preserve one-time pairing and trusted reconnect.

A common private setup looks like this:

1. Run the relay on your Mac, a mini server, or a VPS you control
2. Put that machine on Tailscale
3. Set `OPENDEX_RELAY` to the Tailscale-reachable `ws://` or `wss://` relay URL
4. Pair once with QR
5. Let the iPhone reconnect to the same trusted Mac over that relay later

If that relay is fronting a Mac bridge, the macOS daemon can keep the bridge alive for hands-free reconnects. If you self-host against a non-macOS bridge, the same relay path still works, but automatic background service management is not built in yet.

Reverse-proxy subpaths work too, so a hosted relay behind Traefik can live under the same domain as other APIs:

```sh
OPENDEX_RELAY="wss://api.example.com/opendex/relay" opendex up
```

In that setup, the public endpoints can look like this:

- `wss://api.example.com/opendex/relay`
- `https://api.example.com/opendex/v1/push/session/register-device`
- `https://api.example.com/opendex/v1/push/session/notify-completion`

Have the proxy strip `/opendex` before forwarding so the relay still receives `/relay/...` and `/v1/push/...`.

If you point `OPENDEX_RELAY` at your own self-hosted relay, managed push stays off unless you also set `OPENDEX_PUSH_SERVICE_URL` on the bridge and explicitly enable push on the relay.

## Publish to npm

Published npm packages can embed default private relay settings at pack time via the `prepack` script.

The current package version is `1.3.3`.

To publish the bridge with `api.phodex.app` as the default relay:

```sh
cd phodex-bridge
bunx npm login
OPENDEX_PACKAGE_DEFAULT_RELAY_URL="wss://api.phodex.app/relay" \
bunx npm publish
```

After publish, users can still override the packaged default at runtime with `OPENDEX_RELAY`.

You can also run the bridge from source:

```sh
cd phodex-bridge
bun install
OPENDEX_RELAY="ws://localhost:9000/relay" bun start
```

## Commands

### `opendex up`

Starts Opendex.

On macOS, `opendex up` is the friendly entrypoint for the background bridge service:

- Writes the daemon config used by the `launchd` service
- Starts or restarts the background bridge service
- Waits for a pairing payload and prints a QR for first-time trust or recovery
- Keeps the bridge alive even if you close the terminal later

On non-macOS platforms, `opendex up` runs the bridge in the foreground.

In both cases the bridge:

- Starts the OpenCode-backed runtime transport (or connects to an existing endpoint)
- Connects the Mac bridge to the configured relay
- Forwards JSON-RPC messages bidirectionally
- Handles git commands from the phone
- Persists the active thread for later resumption

### `opendex start`

macOS only. Starts the background bridge service without waiting for or printing a QR in the current terminal.

### `opendex stop`

macOS only. Stops the background bridge service and clears its transient runtime status.

### `opendex status`

macOS only. Prints the current `launchd` / bridge status, including whether the service is loaded and whether a recent pairing payload exists.

### `opendex run-service`

macOS only. Internal service entrypoint used by `launchd`. You normally do not run this manually.

### `opendex --version`

Prints the installed Opendex CLI version.

```sh
opendex --version
# => 1.3.3
```

### `opendex reset-pairing`

Clears the saved bridge pairing state so the next trusted connection requires a fresh QR bootstrap again.
You normally do not need this for corrupted local state anymore: recent Opendex builds auto-repair unreadable pairing files/mirrors on startup.

```sh
opendex reset-pairing
# => [opendex] Cleared the saved pairing state. Run `opendex up` to pair again.
```

### `opendex resume`

Reopens the last active thread in desktop app on your Mac.

```sh
opendex resume
# => [opendex] Opened last active thread: abc-123 (phone)
```

### `opendex watch [threadId]`

Tails the event log for a thread in real-time.

```sh
opendex watch
# => [14:32:01] Phone: "Fix the login bug in auth.ts"
# => [14:32:05] OpenCode: "I'll look at auth.ts and fix the login..."
# => [14:32:18] Task started
# => [14:33:42] Task complete
```

## Environment Variables

`OPENDEX_RELAY` is optional, but the default depends on how you got Opendex:

- public GitHub/source checkouts stay open-source and self-host friendly, so they do not ship with a hosted relay baked in
- official published packages may include a default relay at publish time
- if you are running from source, assume you should use `./run-local-opendex.sh` or set `OPENDEX_RELAY` yourself

| Variable                      | Default                                                   | Description                                                                                    |
| ----------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `OPENDEX_RELAY`               | empty in source checkouts; optional in published packages | Session base URL used for QR bootstrap, trusted-session resolve, and phone/Mac session routing |
| `OPENDEX_PUSH_SERVICE_URL`    | disabled by default                                       | Optional HTTP base URL for managed push registration/completion                                |
| `OPENDEX_OPENCODE_ENDPOINT`   | `http://127.0.0.1:4096`                                   | Connect to an existing OpenCode HTTP server instead of relying on the local default            |
| `OPENDEX_REFRESH_ENABLED`     | `false`                                                   | Auto-refresh desktop app when phone activity is detected (`true` enables it explicitly)        |
| `OPENDEX_REFRESH_DEBOUNCE_MS` | `1200`                                                    | Debounce window (ms) for coalescing refresh events                                             |
| `OPENDEX_REFRESH_COMMAND`     | —                                                         | Custom shell command to run instead of the built-in AppleScript refresh                        |
| `OPENDEX_DESKTOP_BUNDLE_ID`   | `com.openai.codex`                                        | macOS bundle ID of the desktop app                                                             |
| `CODEX_HOME`                  | `~/.opencode`                                             | Legacy-compatible runtime data directory used for `sessions/` rollout files                    |

```sh
# Enable desktop refresh explicitly
OPENDEX_REFRESH_ENABLED=true opendex up

# Connect to an existing OpenCode instance
OPENDEX_OPENCODE_ENDPOINT=http://127.0.0.1:4096 opendex up

# Use a custom self-hosted relay endpoint (`ws://` is unencrypted)
OPENDEX_RELAY="ws://localhost:9000/relay" opendex up

# Enable managed push only if your self-hosted relay also exposes a configured APNs push service
OPENDEX_RELAY="wss://relay.example/relay" \
OPENDEX_PUSH_SERVICE_URL="https://relay.example" \
opendex up
```

On the relay/VPS side, keep push disabled until you actually want it. The HTTP push endpoints are off by default and only turn on when you set `OPENDEX_ENABLE_PUSH_SERVICE=true`.

## Pairing and Safety

- Opendex is local-first: OpenCode, git operations, and workspace actions run on your Mac, while the iPhone acts as a paired remote control.
- On iPhone, the most reliable self-host setup is a Tailscale-reachable relay. Plain LAN pairing over `ws://` on the same Wi-Fi can fail on some iOS devices because local-network routing from the app is not always reliable.
- The pairing QR carries the connection URL, the session ID, and the bridge identity key used to bootstrap end-to-end encryption. After a successful first scan, the iPhone stores a trusted Mac record in Keychain and the bridge persists its trusted phone identity locally on the Mac.
- On macOS, the bridge can keep running as a lightweight `launchd` service, so the phone can resolve the Mac's current live relay session and reconnect without scanning a new QR every time.
- The QR is still the recovery path when trust changes, the bridge identity rotates, or the relay cannot resolve the current live session.
- The bridge state lives canonically in `~/.opendex/device-state.json` with local-only permissions. On macOS the bridge also mirrors that state to Keychain as best-effort backup/migration data, and recent builds auto-repair unreadable local state on startup instead of requiring manual cleanup.
- The CLI no longer prints the connection URL in plain text below the QR.
- Set `OPENDEX_RELAY` only when you want to self-host or test locally against your own setup.
- Leave `OPENDEX_TRUST_PROXY` unset for direct/self-hosted installs. Turn it on only when a trusted reverse proxy such as Traefik, Nginx, or Caddy is forwarding the relay traffic.
- The transport implementation is public in [`relay/`](relay/), but your real deployed hostname and credentials should stay private.
- On the iPhone, the default agent permission mode is `On-Request`. Switching the app to `Full access` auto-approves runtime approval prompts from the agent.

## Security and Privacy

Opendex now uses an authenticated end-to-end encrypted channel between the paired iPhone and the bridge running on your Mac. The transport layer still carries the WebSocket traffic, but it does not get the plaintext contents of prompts, tool calls, OpenCode responses, git output, or workspace RPC payloads once the secure session is established.

The secure channel is built in these steps:

1. The bridge generates and persists a long-term device identity keypair on the Mac.
2. The pairing QR shares the connection URL, session ID, bridge device ID, bridge identity public key, and a short expiry window.
3. During pairing, the iPhone and bridge exchange fresh X25519 ephemeral keys and nonces.
4. The bridge signs the handshake transcript with its Ed25519 identity key, and the iPhone verifies that signature against the public key from the QR code or the previously trusted Mac record.
5. The iPhone signs a client-auth transcript with its own Ed25519 identity key, and the bridge verifies that before accepting the session.
6. Both sides derive directional AES-256-GCM keys with HKDF-SHA256 and then wrap application messages in encrypted envelopes with monotonic counters for replay protection.

Privacy notes:

- The transport layer can still see connection metadata and the plaintext secure control messages used to set up the encrypted session, including session IDs, device IDs, public keys, nonces, and handshake result codes.
- The transport layer does not see decrypted application payloads after the secure handshake succeeds.
- A fresh QR scan can replace the previously trusted iPhone automatically. Use `opendex reset-pairing` only when you intentionally want to wipe the remembered pairing state yourself.
- On-device message history is also encrypted at rest on iPhone using a Keychain-backed AES key.

## Git Integration

The bridge intercepts `git/*` JSON-RPC calls from the phone and executes them locally:

| Command             | Description                                             |
| ------------------- | ------------------------------------------------------- |
| `git/status`        | Branch, tracking info, dirty state, file list, and diff |
| `git/commit`        | Commit staged changes with an optional message          |
| `git/push`          | Push to remote                                          |
| `git/pull`          | Pull from remote (auto-aborts on conflict)              |
| `git/branches`      | List all branches with current/default markers          |
| `git/checkout`      | Switch branches                                         |
| `git/createBranch`  | Create and switch to a new branch                       |
| `git/log`           | Recent commit history                                   |
| `git/stash`         | Stash working changes                                   |
| `git/stashPop`      | Pop the latest stash                                    |
| `git/resetToRemote` | Hard reset to remote (requires confirmation)            |
| `git/remoteUrl`     | Get the remote URL and owner/repo                       |

## Workspace Integration

The bridge also handles local workspace-scoped revert operations for the assistant revert flow:

| Command                        | Description                                                             |
| ------------------------------ | ----------------------------------------------------------------------- |
| `workspace/revertPatchPreview` | Checks whether a reverse patch can be applied cleanly in the local repo |
| `workspace/revertPatchApply`   | Applies the reverse patch locally when the preview succeeds             |

## Desktop App Integration

Opendex works with both OpenCode CLI and the desktop app. Under the hood, the bridge now prefers an OpenCode-backed HTTP transport adapter, while still preserving legacy Codex-compatible behavior where the app and bridge expect it. Conversations are still persisted under `~/.opencode/sessions`, so threads started from your phone can show up in the desktop app too.

What is live today:

- The iPhone conversation is live while the bridge session is connected.
- The Mac-side OpenCode runtime is the real runtime doing the work.

What is not fully live today:

- The desktop app does not act like a second live subscriber to the active run by default.
- The desktop app catches up from the persisted session files and can be nudged with the optional refresh workaround below.
- True phone-to-desktop live sync in the desktop GUI is not supported today.

To make that limitation more practical, Opendex also includes a hand-off button in the iPhone app. It lets you explicitly continue the current chat on your Mac by opening the matching thread in the desktop app when you are ready to switch devices.

**Known limitation**: The desktop app does not live-reload when an external process writes new data to disk. Threads created or updated from your phone won't appear in the desktop app until it remounts that route. Opendex keeps desktop refresh off by default for now because the current deep-link bounce is still disruptive. You can still enable it manually if you want the old remount workaround.

```sh
# Enable the old deep-link refresh workaround manually
OPENDEX_REFRESH_ENABLED=true opendex up
```

This triggers a debounced deep-link bounce (`codex://settings` → `codex://threads/<id>`) that forces the desktop app to remount the current thread without interrupting any running tasks. While a turn is running, Opendex also watches the persisted rollout for that thread and issues occasional throttled refreshes so long responses become visible on Mac without a full app relaunch. If the local desktop path is unavailable, the bridge self-disables desktop refresh for the rest of that run instead of retrying noisily forever.

## Connection Resilience

- **Auto-reconnect**: If the session connection drops, the bridge reconnects with exponential backoff (1 s → 5 s max)
- **Secure catch-up**: The bridge keeps a bounded local outbound buffer and re-sends missed encrypted messages after a secure reconnect
- **OpenCode persistence**: The OpenCode process stays alive across transient session reconnects during the current bridge run
- **Graceful shutdown**: SIGINT/SIGTERM cleanly close all connections

## Building the iOS App

```sh
cd CodexMobile
open CodexMobile.xcodeproj
```

Build and run on a physical device or simulator with Xcode. The app uses SwiftUI and the current project target is iOS 18.6.

## Contributing

I'm not actively accepting contributions yet. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## FAQ

**Do I need an OpenAI API key?**
Not for Opendex itself. You need OpenCode CLI set up and working independently.

**Does this work on Linux/Windows?**
The core bridge client (OpenCode forwarding + git) works on any OS. Desktop refresh (AppleScript) is macOS-only, and the built-in daemon / trusted auto-reconnect service path is currently macOS-only too.

**What happens if I close the terminal?**
On macOS, the bridge can keep running in the background through `launchd`, so closing the terminal does not stop the trusted reconnect path. On other OSes, the foreground bridge stops when the terminal stops.

**How do I force a fresh QR pairing?**
Run `opendex reset-pairing`, then start the bridge again with `opendex up`. You should only need this when you intentionally want to replace the paired iPhone or wipe the remembered pairing.

**Can I connect to a remote OpenCode instance?**
Yes — set `OPENDEX_OPENCODE_ENDPOINT=http://host:port` to point the bridge at an existing OpenCode server.

**Why don't my phone threads show up in the desktop app immediately?**
The desktop app reads session data from disk (`~/.opencode/sessions`) but doesn't live-reload when an external process writes new data. Your phone still gets the live stream; it is the desktop GUI that lags unless you explicitly enable the refresh workaround with `OPENDEX_REFRESH_ENABLED=true`.

**Does Opendex support true live sync between phone and the desktop app?**
No. The phone session is live, but the desktop GUI is not a true live mirror of the active run. To help with that, the iPhone app includes a `Hand off to Mac app` button so you can explicitly continue the same thread on your Mac.

**Can I self-host the relay?**
Yes. That is the intended forking path. The transport and push-service code are in [`relay/`](relay/); point `OPENDEX_RELAY` at the instance you run.

**Can I use Tailscale?**
Yes. It is the recommended private-network option for self-hosting on iPhone. Run your relay somewhere reachable over Tailscale, set `OPENDEX_RELAY` to that relay URL, pair once with QR, then let the app reconnect to the trusted Mac through the same relay.

**Is the transport layer safe for sensitive work?**
It is much stronger than a plain text proxy: traffic can be protected in transit with TLS, application payloads are end-to-end encrypted after the secure handshake, and all OpenCode execution still happens on your Mac. The transport can still observe connection metadata and handshake control messages, so the tightest trust model is to run it yourself.

## License

[ISC](LICENSE)
