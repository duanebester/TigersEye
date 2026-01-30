# TigersEye 🐯👁️

A beautiful TigerbeetleDB GUI client built with [Gooey](https://github.com/duanebester/gooey).

## Features

- **Real-time account management** - View, create, and manage TigerbeetleDB accounts
- **Transfer funds** - Execute transfers between accounts with instant feedback
- **Dark cyber theme** - Inspired by tigerbeetle.com's design language
- **Native performance** - Built with Zig, zero runtime overhead
- **Thread-safe async** - GCD-based dispatcher for smooth UI updates

## Prerequisites

1. **Zig 0.15.2 or later**
2. **TigerbeetleDB server running locally**
   ```bash
   # Start a local TigerbeetleDB instance
   ./tigerbeetle start --addresses=3000 ./0_0.tigerbeetle
   ```
3. **TigerbeetleDB client library** (`libtb_client.dylib` for macOS)
   - Place in `vendor/tigerbeetle/lib/`

## Building

```bash
# Build the application
zig build

# Run TigersEye
zig build run
```

## Project Structure

```
TigersEye/
├── src/
│   └── main.zig           # Application entry point and UI
├── vendor/
│   └── tigerbeetle/
│       ├── tb_client.zig  # TigerbeetleDB Zig bindings
│       └── lib/           # Platform-specific client libraries
├── docs/
│   └── INTEGRATION.md     # Hard-won integration lessons
├── build.zig
└── build.zig.zon
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  UI Event (button click)                                         │
│    ↓ cx.command(AppState, AppState.refreshAccounts)              │
├─────────────────────────────────────────────────────────────────┤
│  TBClient.queryAccounts(packet, filter)                          │
│    ↓ (async, TigerBeetle IO thread)                              │
├─────────────────────────────────────────────────────────────────┤
│  tbCompletionCallback → dispatcher.dispatchOnMainThread          │
│    ↓ (main thread)                                               │
├─────────────────────────────────────────────────────────────────┤
│  AppState.applyResult() → gooey.requestRender()                  │
└─────────────────────────────────────────────────────────────────┘
```

## Configuration

Edit constants in `src/main.zig`:

```zig
const DEFAULT_ADDRESS = "127.0.0.1:3000";  // TigerbeetleDB server
const MAX_ACCOUNTS = 1024;                  // Account list limit
const USE_ECHO_CLIENT = false;              // true for testing without server
```

## Theme

TigersEye uses TigerbeetleDB's official color palette:

| Color  | Hex       | Usage                |
|--------|-----------|----------------------|
| Lime   | `#c4f042` | Primary actions      |
| Cyan   | `#8ae8ff` | Links, highlights    |
| Mint   | `#93fdb5` | Success, credits     |
| Purple | `#9e8cfc` | Secondary actions    |
| Yellow | `#ffef5c` | Warnings             |
| Danger | `#f16153` | Errors, debits       |

## License

MIT License - See [LICENSE](LICENSE)

## Acknowledgments

- [TigerbeetleDB](https://tigerbeetle.com/) - The financial database
- [Gooey](https://github.com/duanebester/gooey) - Zig UI framework
