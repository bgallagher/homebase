# Rackoon for Android

Native Kotlin and Jetpack Compose, built in approved stages (see `docs/android-spikes.md` for the stack decision and the
spike results). **Stages A1 (portable core) and A2 (SSH module and probe) are done.** The app (A3+) has servers, host-key trust, the Overview and now the terminal; the theme picker, SSH key/password auth and release packaging are still to do. First release: themes, Overview, terminal.

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
./gradlew :core:test :ssh:test            # 141 + 8 tests; needs JDK 21
./gradlew :probe:run --args="hetzner overview"   # real server, read-only (see the check list above)
```

CI runs the same (`android-core` job). Android Studio opens `android/` directly once the app module exists.

## Differences from the Swift core (on purpose)

- Sessions expose `StateFlow` instead of `AsyncStream`, and are driven by coroutines.
- `Confirmation` has a module-internal constructor: only `ActionPolicy.confirm` can make one from another module.
- A cancelled `StreamRunner.run` returns normally with `cancelled = true` (like the Swift one), so callers can still clean up.
- Not ported (Mac-only or later stages): `SSHConfig`, `ServerStore`, `LicenceKey`, favicon fetching, the compose/.env editor
  stack (`ComposeFormParser`, `ContainerSpec`, `NewStack`, `StackFiles*`, `EditorChecks`, `LineDiff`, `SyntaxHighlighter`),
  `RemoteFiles`, `StackRemoval`.

- Regexes in core must also compile on Android's ICU engine, which the JVM tests cannot show: no `(?U)` flag (use explicit `\p{L}\p{N}` classes) and escape `:` inside classes (`[:` starts a POSIX class). Both crashed the phone once.
