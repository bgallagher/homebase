# Rackoon for Android

Native Kotlin and Jetpack Compose, built in approved stages (see `docs/android-spikes.md` for the stack decision and the
spike results). **Stages A1 (portable core) and A2 (SSH module and probe) are done.** The app (A3+) has servers, host-key trust, the Overview and now the terminal; the theme picker, SSH key and password sign-in (Keystore-encrypted), server settings and the snapshot cache are in; the Docker overview (stack cards, links with Local/Tailscale/Public tags, a read-only stack page) and Bookmarks (list, add, edit, remove, written into compose files) and the container and stack actions (start, stop, restart, rebuild, recreate, pull, update, Shell, with a confirmation and live Output) Add container (a new stack from a form or a pasted compose.yaml, or one more service in an existing stack, with server-side checks), Delete stack (docker compose down, optional volumes and folder, typed name, the Mac's folder-safety rules) and the compose.yaml/.env editor (line numbers, highlighting, the server's own checks, diff-confirmed save, redeploy, conflict handling) site icons (`FaviconLinks` in core, `FaviconStore` on the phone: 128 px PNG cache, daily retry, letter-tile fallback; cleartext http is allowed app-wide because the icon fetcher is the only HTTP client) the Updates page with Install and Refresh (live apt output) and Reboot with wait-for-return, and the stack Logs tab (merged follow, per-container focus, level chips, search, pause/Latest, copy) are in; release packaging is still to do, and the alpha waits for feature parity with the Mac app (Docker, Bookmarks and Updates are done; Commands and Files are not). First release: themes, Overview, terminal.

```
android/
  core/    pure Kotlin/JVM: a mirror of apple/Packages/RackoonCore (models, parsers, sessions, ActionPolicy, ShellQuote,
           log and stream helpers, command library, themes, output highlighter). No Android or SSH imports.
  ssh/     sshj behind core's SSHTransport: one connection for commands, a pty connection for streams (Ctrl-C on cancel),
           terminal shells with resize, host-key trust (SHA256 fingerprints, trust-on-first-use, changed key blocked)
  app/     Jetpack Compose UI; terminal = ConnectBot termlib fed by `TerminalTab` (reconnect via ReconnectPolicy, extra keys,
           output highlighting) held by `TerminalManager`, kept alive by a foreground `SessionService`
  probe/   a JVM CLI for real-server checks: ./gradlew :probe:run --args="<host> overview|hostkey|stream-check|stream-marker|shell-check"
```

## The contract

`spec/` is the source of truth, shared with the Swift core:

- `spec/fixtures/**` golden files: every Kotlin parser must produce exactly what the Swift one does (compared as JSON, numbers
  by value).
- `spec/commands.json` and `spec/command-library.json`: the shell commands. Unlike the Swift core, Kotlin keeps **no copy**:
  Gradle bundles these files into the module's resources and the code reads them (`SpecCommands`, `CommandLibrary`).
- `apple/Apps/RackoonMac/Resources/themes.json`: the 45 terminal themes, shared the same way (`ThemeCatalog.bundled()`).

## Commands

```
cd android
./gradlew :core:test :ssh:test            # 280 + 14 tests; needs JDK 21
./gradlew :probe:run --args="hetzner overview"   # real server, read-only (see the check list above)
./gradlew :probe:run --args="hetzner compose-test"    # REAL pull/update/rebuild/recreate on a throwaway stack it makes and removes under /tmp
./gradlew :probe:run --args="hetzner newstack-test"   # REAL new-stack check/create on a throwaway folder under /tmp
./gradlew :probe:run --args="hetzner checks-test"   # read-only: image lookup on the registry and listening ports
./gradlew :probe:run --args="hetzner delete-test"   # REAL stack delete on throwaway stacks under /tmp (container-written, root-owned data)
./gradlew :probe:run --args="hetzner env-test"   # REAL .env create/edit/guards on a throwaway stack under /tmp
./gradlew :probe:run --args="hetzner updates-check"   # read-only: update list vs the Overview, streams apt-get -s upgrade (a simulation), cancel leaves nothing running
./gradlew :probe:run --args="hetzner logs-check"   # follows two real containers merged (read-only) and proves nothing is left running
./gradlew :probe:run --args="hetzner exec-shell-check"   # a command and an interactive program on a pty (what Shell-in-container uses)
./gradlew :probe:run --args="hetzner bookmark-test"   # REAL writes, but only on a throwaway stack it makes and removes under /tmp
```

CI runs the same (`android-core` job). Android Studio opens `android/` directly once the app module exists.

## Differences from the Swift core (on purpose)

- Sessions expose `StateFlow` instead of `AsyncStream`, and are driven by coroutines.
- `Confirmation` has a module-internal constructor: only `ActionPolicy.confirm` can make one from another module.
- A cancelled `StreamRunner.run` returns normally with `cancelled = true` (like the Swift one), so callers can still clean up.
- Ported for Bookmarks: `ComposeLabels`, `StackFiles`/`StackFileCommands`/`StackFileSession`, `LineDiff`, `BookmarkEditor`.
- Not ported (Mac-only or later stages): `SSHConfig`, `ServerStore`, `LicenceKey`, the rest of the compose/.env editor
  stack (`ComposeFormParser`, `ContainerSpec`, `NewStack`, `EditorChecks`, `SyntaxHighlighter`),
  `RemoteFiles`, `StackRemoval`.

- Regexes in core must also compile on Android's ICU engine, which the JVM tests cannot show: no `(?U)` flag (use explicit `\p{L}\p{N}` classes) and escape `:` inside classes (`[:` starts a POSIX class). Both crashed the phone once.

## Demo mode and the sandbox (for trying things without touching a real server)

- **Demo mode (debug builds only):** `adb shell run-as com.bgallagher.rackoon touch files/demo.flag`, then restart the app (`am force-stop`, then start it); `rm files/demo.flag` goes back to normal. (A cold start with `am start -S -n com.bgallagher.rackoon/.MainActivity --ez demo true` works too, when no other instance is running.) The app runs against three made-up servers (homelab with 9 stacks and an unhealthy container, garage-nuc, and old-nas which is always unreachable), with its own empty storage; nothing is read from or written to your real servers, keys or settings. Fake connections answer the same commands the app really sends, and actions change the fake world (a restart, an update that picks up edited labels, a save through the compose editor). A release build has no demo code at all. An emulator works well for this: `emulator -avd Medium_Phone_API_37.0 -no-window`.
- **Sandbox stack on a real server:** `./gradlew :probe:run --args="hetzner sandbox-up"` creates ONE harmless stack (`/tmp/rackoon-sandbox`, project `rackoonsandbox`: a hello page on 127.0.0.1:18080 and redis) so the phone's Docker actions can be tried on it; `sandbox-down` removes exactly that stack and folder. Your own stacks are never touched.

## Releasing

`git tag android-v0.1.0-alpha.1 && git push origin android-v0.1.0-alpha.1` builds, signs and publishes "Rackoon for Android 0.1.0-alpha.1" (one universal APK plus a `.sha256`; a version with a suffix is a pre-release). The signing key comes from the repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`; it is never in the repo. To build a signed APK locally, export `ANDROID_KEYSTORE_FILE` (plus the password and alias variables) and run `./gradlew :app:assembleRelease`; without them the APK is left unsigned. A release build has no demo code. Installing a release over a debug build needs the debug app uninstalled first (different signing key).
