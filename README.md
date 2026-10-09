# Homebase

Agentless SSH server manager for self-hosters (Docker Compose and Tailscale). Mac first, then iPhone and Android. See [docs/PRD.md](docs/PRD.md).

## Layout
- `spec/` — language-neutral contract (commands, models, attention rules, fixtures). Edit first; platform code follows.
- `apple/` — Swift packages (`HomebaseCore`, `HomebaseSSHSystem`) and the Mac app.
- `android/` — reserved for the Kotlin core and Compose app (Phase 4).
- `tools/` — `check-spec` validates the spec; fixture capture comes in Stage 2.

## Develop
```
cd apple && swift test      # Core tests
cd apple && swift run HomebaseMac
python3 tools/check-spec
```
