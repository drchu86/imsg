# imsg — Claude Code Guide

## Project Overview
Swift CLI tool for reading/sending iMessages from the terminal. Targets macOS 14+, Swift 6 (`swift-tools-version: 6.0`).

Two products:
- `imsg` — executable CLI
- `IMsgCore` — library (SQLite access, message watching, sending)

## Build & Test

```bash
make test        # generate version, patch deps, run swift test
make build       # universal release build → bin/
make lint        # swift-format lint + swiftlint
make format      # swift-format in-place
make imsg ARGS="chats --limit 5"  # clean debug build + run
```

> `scripts/generate-version.sh` must run before builds (regenerates `Version.swift` and `Info.plist` from `version.env`).
> `scripts/patch-deps.sh` patches SwiftPM dependencies for macOS compatibility — always run before `swift test` or `swift build`.

## Architecture

```
Sources/
  imsg/
    Commands/           ← one file per subcommand
    CommandRouter.swift ← registers all specs in the `specs` array
    CommandSpec.swift   ← CommandSpec struct definition
    CommandSignatures.swift ← shared option/flag builders
    HTTPServer.swift    ← Hummingbird 2 REST + SSE server
    RPCServer.swift     ← JSON-RPC 2.0 over stdin/stdout (deprecated)
    RPCPayloads.swift   ← shared payload builder functions
    OutputModels.swift  ← Codable output structs (ChatPayload, MessagePayload, etc.)
    RuntimeOptions.swift
    JSONLines.swift
  IMsgCore/
    MessageStore.swift  ← SQLite DB access (@unchecked Sendable)
    MessageWatcher.swift ← DispatchSource filesystem watcher
    MessageSender.swift ← AppleScript/ScriptingBridge sender
    MessageFilter.swift
    Models.swift
    Errors.swift
```

## Adding a New Command

1. Create `Sources/imsg/Commands/FooCommand.swift`:
   ```swift
   enum FooCommand {
     static let spec = CommandSpec(
       name: "foo",
       abstract: "Short description",
       discussion: nil,
       signature: CommandSignatures.withRuntimeFlags(
         CommandSignature(
           options: CommandSignatures.baseOptions() + [
             .make(label: "myOpt", names: [.long("my-opt")], help: "..."),
           ]
         )
       ),
       usageExamples: ["imsg foo --my-opt bar"]
     ) { values, runtime in
       // implementation
     }
   }
   ```

2. Register in `CommandRouter.swift` by adding `FooCommand.spec` to the `specs` array.

## Key Patterns

**Global flags** (available on every command via `CommandSignatures.withRuntimeFlags`):
- `--json` → `runtime.jsonOutput` — emit newline-delimited JSON
- `--verbose` → `runtime.verbose`
- `--db <path>` → override SQLite path (default: `~/Library/Messages/chat.db`)

**JSON output**: use `JSONLines.print(SomeCodable)` — writes one JSON object per line to stdout.

**Output models**: define a `Codable` struct in `OutputModels.swift` with `snake_case` `CodingKeys`.

**HTTP server** (`imsg serve`): Hummingbird 2, default `127.0.0.1:3939`, base path `/v1`. Auth via `IMSG_HTTP_TOKEN` env var → Bearer token. See `HTTPServer.swift` and `docs/serve.md`.

**RPC server** (`imsg rpc`): JSON-RPC 2.0 over stdin/stdout — deprecated in favour of `imsg serve`.

## Dependencies
- [Commander](https://github.com/steipete/Commander) — CLI parsing
- [SQLite.swift](https://github.com/stephencelis/SQLite.swift) — DB access
- [PhoneNumberKit](https://github.com/marmelroy/PhoneNumberKit) — phone number normalization
- [Hummingbird 2](https://github.com/hummingbird-project/hummingbird) — HTTP server (NIO-based)

## Releasing
See `docs/RELEASING.md`. Short version: update `CHANGELOG.md` + `version.env`, run `scripts/generate-version.sh`, then `make lint && make test` before tagging.
