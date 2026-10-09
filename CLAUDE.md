# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Homebase is an agentless SSH server manager for self-hosters (Docker Compose + Tailscale). Mac app first (SwiftUI), then iPhone, then Android. Product scope, MVP requirements (M1–M12) and phase gates are in [docs/PRD.md](docs/PRD.md). Only the MVP is scoped in detail. Work proceeds in approved stages (Stage 0 bootstrap is done); do not build ahead of the stage the user has approved.

## Commands

Run from the repo root unless noted. In interactive zsh, don't paste commands with trailing `# comments` (they become arguments).

```
python3 tools/check-spec                  # validate spec/ (JSON parses, every command has fixtures + expected output)
cd apple && swift build --product HomebaseMac
cd apple && swift run HomebaseMac         # launches the Mac app window (Ctrl+C to quit)
cd apple && swift test                    # needs full Xcode (XCTest); fails with Command Line Tools only
cd apple && swift test --filter ModelsTests/testServerRoundTripsThroughJSON   # single test
```

No linter or formatter is configured yet (`swift-format` is not installed). CI is `.github/workflows/ci.yml` (check-spec on Linux; `swift test` and build on macOS).

The dev machine currently has only Command Line Tools, no Xcode. There is no `.xcodeproj` yet. The Mac app is a SwiftPM executable target, which needs the `AppDelegate` activation-policy workaround in `HomebaseApp.swift` to show a window under `swift run`. A real Xcode project is needed before signing and notarizing.

## Architecture

**Two native cores kept in parity by a shared spec.** The server logic (shell commands, text parsers, attention rules) is small. It is implemented twice: Swift in `apple/` and, in Phase 4, Kotlin in `android/`. `spec/` is the language-neutral source of truth, so edit `spec/` first and make platform code follow:
- `spec/commands.json`: every shell command we run on a server (id, script, timeout, distros).
- `spec/models.schema.json`, `spec/attention-rules.json`: model shapes and the needs-attention rules.
- `spec/fixtures/<command-id>/NAME.out.txt` + `NAME.expected.json`: captured real output and the expected parse. Every platform's parsers must match these golden files. `tools/check-spec` fails if a command has no fixtures or a fixture has no expected output.

**Layering (same on every platform):** UI → view model/state → services → `SSHTransport` → SSH implementation.
- `HomebaseCore` (`apple/Packages/HomebaseCore`) is Foundation-only and must never import SwiftUI, AppKit or `Process`. It defines the `SSHTransport` protocol (`run`, `stream`) that every transport implements. Services take a transport by injection, so tests use a fake that replays fixtures.
- `HomebaseSSHSystem` is macOS-only. `OpenSSHTransport` will wrap `/usr/bin/ssh` (ControlMaster, BatchMode) so `~/.ssh/config` and ssh-agent work. It is a stub (`fatalError`) until Stage 1. An embedded-SSH transport (App Store, iOS, Android) swaps in later without touching Core.
- `HomebaseMac` (`apple/Apps/HomebaseMac`) is the thin SwiftUI app. It depends on both packages.
- The single `apple/Package.swift` uses custom `path:` entries into `Packages/*/Sources/*`, so the layout is not the SwiftPM default.

**Design constraints to keep Android and the App Store possible:**
- No Mac-only assumptions in Core. `~/.ssh/config` parsing is a Mac-app feature that produces plain `Server` models.
- Parsers stay simple (line/column splitting, or JSON from `docker ps --format json`) so they port 1:1 to Kotlin.
- Planned: one `ServerSession` actor per server owns a transport, a 5 s poll loop and the last snapshot. Views never call SSH directly. A global read-only flag is checked in the service layer.
- The server stays untouched: no agent, standard SSH commands only (Debian/Ubuntu and apt for the MVP).
