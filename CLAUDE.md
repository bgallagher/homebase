# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Homebase is an agentless SSH server manager for self-hosters (Docker Compose + Tailscale). Mac app first (SwiftUI), then iPhone, then Android. Product scope, MVP requirements (M1–M12) and phase gates are in [docs/PRD.md](docs/PRD.md). Only the MVP is scoped in detail. Work proceeds in approved stages (Stages 0 to 3 done: bootstrap, SSH transport + terminal spike, Overview/attention, saved servers + host-key trust, terminal tabs, Docker); do not build ahead of the stage the user has approved.

## Commands

Run from the repo root unless noted. In interactive zsh, don't paste commands with trailing `# comments` (they become arguments).

```
python3 tools/check-spec                  # validate spec/ (JSON parses, every command has fixtures + expected output)
cd apple && swift build --product HomebaseMac
cd apple && swift run HomebaseMac         # launches the Mac app window (Ctrl+C to quit)
cd apple && swift test                    # needs full Xcode with its licence accepted (XCTest)
cd apple && swift test --filter ModelsTests/testServerRoundTripsThroughJSON   # single test
```

```
tools/capture-fixtures <ssh-host> <command-id> <name>   # save a real command's output as spec/fixtures/<id>/<name>.out.txt
cd apple && swift run homebase-probe <host> overview    # headless two-poll check of ServerSession against a real host
cd apple && swift run homebase-probe <host> docker      # Docker poll + harmless action checks against a real host
cd apple && swift run homebase-probe <host> logs <container>  # stream logs 4 s, cancel, check no remote process is left
cd apple && swift run homebase-probe <host> hostkey     # unknown -> trust -> tampered flow, using a throwaway known_hosts
```

No linter or formatter is configured yet (`swift-format` is not installed). CI is `.github/workflows/ci.yml` (check-spec on Linux; `swift test` and build on macOS).

Xcode is installed on the dev machine. There is no `.xcodeproj` yet. The Mac app is a SwiftPM executable target, which needs the `AppDelegate` activation-policy workaround in `HomebaseApp.swift` to show a window under `swift run`. A real Xcode project is needed before signing and notarizing.

## Architecture

**Two native cores kept in parity by a shared spec.** The server logic (shell commands, text parsers, attention rules) is small. It is implemented twice: Swift in `apple/` and, in Phase 4, Kotlin in `android/`. `spec/` is the language-neutral source of truth, so edit `spec/` first and make platform code follow:
- `spec/commands.json`: every shell command we run on a server (id, script, timeout, distros).
- `spec/models.schema.json`, `spec/attention-rules.json`: model shapes and the needs-attention rules.
- The Swift command string (`ServerSession.overviewCommand`) must equal the `script` in `commands.json`; a test enforces it. Edit both together.
- `spec/fixtures/<command-id>/NAME.out.txt` + `NAME.expected.json`: captured real output and the expected parse. Every platform's parsers must match these golden files. `tools/check-spec` fails if a command has no fixtures or a fixture has no expected output.

**Layering (same on every platform):** UI → view model/state → services → `SSHTransport` → SSH implementation.
- `HomebaseCore` (`apple/Packages/HomebaseCore`) is Foundation-only and must never import SwiftUI, AppKit or `Process`. It defines the `SSHTransport` protocol (`run`, `stream`) that every transport implements. Services take a transport by injection, so tests use a fake that replays fixtures.
- `HomebaseSSHSystem` is macOS-only. `OpenSSHTransport` wraps `/usr/bin/ssh` (ControlMaster, BatchMode) so `~/.ssh/config` and ssh-agent work. An embedded-SSH transport (App Store, iOS, Android) swaps in later without touching Core.
- `HomebaseMac` (`apple/Apps/HomebaseMac`) is the thin SwiftUI app. It depends on both packages.
- The single `apple/Package.swift` uses custom `path:` entries into `Packages/*/Sources/*`, so the layout is not the SwiftPM default.

**Design constraints to keep Android and the App Store possible:**
- No Mac-only assumptions in Core. `~/.ssh/config` parsing is a Mac-app feature that produces plain `Server` models.
- Parsers stay simple (line/column splitting, or JSON from `docker ps --format json`) so they port 1:1 to Kotlin.
- `ServerSession` (Core actor) owns one server's transport, the 5 s poll loop and the last good `ServerState`. A failed poll keeps the old data and sets `error`. CPU % needs two readings, so `Overview` carries raw `/proc/stat` counters and `cpuPercent(since:)` does the delta. `ServerModel` (Mac app) bridges the actor to SwiftUI; views never call SSH directly. `Attention.evaluate` is a pure function of an `Overview`.
- Persistence: `ServerStore` (Core) writes `servers.json` and per-server cached snapshots under `~/Library/Application Support/Homebase/`. Secrets never go there. On select, `AppModel` paints the cached snapshot immediately (`ServerState.isStale`) and replaces it on the first successful poll.
- Host keys: `HostKeyVerifier` (SSHSystem) runs ssh with `StrictHostKeyChecking=yes`. Unknown key -> user sees fingerprints and confirms -> exactly the scanned lines are appended to known_hosts. Changed key -> blocked, never offered for acceptance. `AppModel` only polls the selected server.
- `Server.host` is whatever ssh connects to (hostname, IP or ~/.ssh/config alias). Imported servers keep the alias as `host` so ssh applies the rest of the entry.
- Terminals: `TerminalStore` holds each server's `TerminalTab`s; a tab owns its SwiftTerm `LocalProcessTerminalView` (not SwiftUI), so sessions survive switching screens, tabs and servers, and end only on tab close, server removal or quit. Tabs run `ssh -t` over the same ControlPath as `OpenSSHTransport`, so a new tab reuses the open connection (about 0.17 s vs 0.8 s). Cmd+T / Cmd+W are menu commands (`TerminalCommands`) that replace File > Close and fall back to closing the window when no terminal is showing.
- Docker: `DockerSession` (Core actor, polls every 10 s only while the Docker screen is open, because `docker stats` takes ~2.5 s) parses `docker ps -a` + `docker stats` into stacks grouped by compose project label. Actions (`start/stop/restart`) and logs only accept a hex container id (`DockerSession.isContainerID`), since the id is interpolated into a remote shell command. The Overview command also lists unhealthy container names, which feed the attention strip; each chip links to its `fix` screen.
- Streams (`OpenSSHTransport.stream`, used for logs) deliberately use their own connection with `-tt`, not the shared ControlMaster: stopping a stream sends Ctrl-C through the pty, and tested behaviour is that Ctrl-C reaches the remote command on its own connection but not through a multiplexed one. Merely killing the local ssh leaves `docker logs -f` running forever on Tailscale SSH servers.
- Fixtures from real servers must be sanitized before committing (IPs, private container names, emails). `spec/fixtures/**/raw-*` is git-ignored for raw captures. Golden files may be generated with `HOMEBASE_WRITE_GOLDEN=1 swift test`; review them by hand.
- Not built yet: Docker pull/recreate/rebuild/update checks, Keychain secrets (BatchMode means password auth does not work; keys and ssh-agent do), editing a server, automatic terminal reconnect (a dead tab shows a Reconnect button), a global read-only flag checked in the service layer.
- The server stays untouched: no agent, standard SSH commands only (Debian/Ubuntu and apt for the MVP).
