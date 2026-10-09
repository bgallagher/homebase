# Spec: the shared contract

Source of truth for every platform. Swift and Kotlin cores both implement it and are held to parity by the golden fixtures.

- `commands.json` — every shell command we run (id, script, timeout, distro).
- `models.schema.json` — JSON Schema for the parsed models.
- `attention-rules.json` — rules behind the needs-attention strip.
- `fixtures/<command-id>/NAME.out.txt` + `NAME.expected.json` — captured stdout and the expected parsed result. Both platforms' parsers must match.

`python3 tools/check-spec` enforces consistency.
