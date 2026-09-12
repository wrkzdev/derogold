# DeroGold Wallet — desktop

A Flutter desktop wallet for DeroGold. Every wallet operation goes through
`wallet_capi`, a C shared library built from this repository's own wallet
backend and loaded over Dart FFI — there is no daemon subprocess in the way and
no wallet-api service to run.

## Requirements

| Tool | Version |
|------|---------|
| Flutter | 3.38.7+ |
| Dart | 3.10.7+ |
| CMake | 3.15+ |
| Visual Studio 2022 | with "Desktop development with C++" (Windows) |
| GCC / Clang | GCC 11+ or Clang 14+ (Linux / macOS) |

Enable desktop support once:

```bash
flutter config --enable-windows-desktop
flutter config --enable-linux-desktop
flutter config --enable-macos-desktop
```

---

## Quick start

### 1. Build wallet_capi

From the repository root. `DEROGOLD_BUILD_EXECUTABLES=OFF` keeps the daemon,
the CLI wallet and RocksDB out of a build that only needs the library:

**Linux / macOS**
```bash
cmake -S . -B build -D CMAKE_BUILD_TYPE=Release \
    -D DEROGOLD_BUILD_WALLET_CAPI=ON -D DEROGOLD_BUILD_EXECUTABLES=OFF
cmake --build build --target wallet_capi
```
Output: `build/src/libwallet_capi.so` (`.dylib` on macOS)

**Windows**
```bash
cmake -S . -B build -G "Visual Studio 17 2022" ^
    -D DEROGOLD_BUILD_WALLET_CAPI=ON -D DEROGOLD_BUILD_EXECUTABLES=OFF
cmake --build build --target wallet_capi --config Release
```
Output: `build\src\Release\wallet_capi.dll`

### 2. Put the library where the app will find it

`DynamicLibrary.open` takes the bare filename, so the library has to sit next
to the Flutter executable (or anywhere else the platform's loader searches).

| Platform | Library | Destination |
|----------|---------|-------------|
| Windows | `wallet_capi.dll` | `build\windows\x64\runner\Debug\` or `Release\` |
| Linux | `libwallet_capi.so` | `build/linux/x64/debug/bundle/` or `release/bundle/` |
| macOS | `libwallet_capi.dylib` | next to `derogold_wallet.app` |

### 3. Run

```bash
cd extras/desktop-wallet
flutter pub get
flutter run -d windows   # or linux / macos
```

---

## Configuration

Defaults live in [lib/core/config/app_config.dart](lib/core/config/app_config.dart):

| Constant | Default | |
|----------|---------|---|
| `kDefaultDaemonHost` | `dego-node-rpc.0z.network` | change it to your own node if you run one |
| `kDefaultDaemonPort` | `6969` | `RPC_DEFAULT_PORT` |
| `kCoinTicker` | `DEGO` | |
| `kCoinDecimalPlaces` | `2` | 100 atomic units = 1.00 DEGO |
| `kAddressPrefix` | `dg` | addresses are 97 characters, 185 when integrated |
| `kSlowRescanHeight` | `2900000` | below this, a rescan asks for confirmation first |
| `kDefaultTxPowServerHost` | `dego-txpow-rpc.0z.network` | port 80, no SSL; the switch is still off by default |

Node address, theme and log level are stored with `flutter_secure_storage` and
can be changed from **Settings** at runtime.

---

## Features

- **Overview** — balance (unlocked / locked), sync status, recent transactions
- **Receive** — primary address + QR code, integrated address generator with payment ID
- **Transfer** — send with fee preview, and a sweep that splits a send over as many transactions as it takes
- **History** — filter, search, paginated, expandable details
- **Address Book** — saved addresses with labels and notes
- **Settings** — node switch with a **Test** button, rescan, export, theme, log level, delete wallet
- **Lock** — saves and closes the wallet, returning to the setup screen
- **Local lite node** — run `DeroGoldd` on this machine and sync against it (below)

### Transaction PoW

Every DeroGold transaction carries a proof of work, which costs this machine a
few seconds of CPU per send. Settings has a **Transaction PoW Server** section
that can hand that work to a `DeroGold-txpow-server` instead. The switch is
**off by default** — the wallet computes the proof itself until someone turns
it on — but the fields come prefilled with the project's public server,
`dego-txpow-rpc.0z.network` on port 80, so enabling it is one switch. Any other
server can be entered instead. The wallet re-verifies every nonce a server
returns and falls back to its own CPU if anything is wrong, so a bad server
only ever costs time. See [TXPOWSERVER.md](../../TXPOWSERVER.md).

### Rescanning

A rescan from far down the chain re-checks every block from there to the tip
and can run for hours. Below `kSlowRescanHeight` the dialog says so and makes
you tick a box before it starts — the same question the CLI wallet asks.

---

## Local lite node

Settings has a **Local Lite Node** card that supervises a `DeroGoldd` child
process, so the wallet can sync against a node you own rather than a public
server.

The daemon is a separate binary, looked for in this order:

1. `$DEROGOLD_DAEMON_PATH`
2. next to the wallet executable
3. a `sidecar/` folder beside it
4. `Contents/Resources/` and `Contents/Resources/sidecar/` (macOS bundle)
5. the working directory, and `sidecar/` inside it (`flutter run`)

```bash
cmake --build build --target DeroGoldd
cp build/src/DeroGoldd extras/desktop-wallet/assets/sidecar/
```

If it is absent the card says so and nothing else in the app changes.

`DEROGOLD_DAEMON_EXTRA_ARGS` appends flags to the daemon's command line, space
separated. The app never sets it; it exists for daemons built without something
the standard argument list assumes — a RocksDB linked without ZSTD needs
`--db-enable-compression=false` or it exits at startup.

| | |
|---|---|
| Data directory | `node-data/` beside the executable for a portable copy, otherwise `<app support>/node`, with its own `derogold-node.json`, pid file and `derogoldd.log` |
| Ports | An ephemeral RPC and P2P port picked once and stored, so the node never collides with a daemon you run yourself |
| RPC binding | `127.0.0.1` only, and **unauthenticated** — anything running as any user on this machine can reach it |
| Console | `--no-console`; the process is stopped by signal |
| Restarts | A node that was running comes back on the next launch. One stopped on purpose stays stopped |
| Quitting the app | Ask, keep running, or stop — your choice is remembered (Settings) |
| Crash recovery | A node left behind by a force-quit app is found by its port, checked against the configured lite height, and adopted rather than started twice |

### The start height is the whole decision

It is permanent for the database: the daemon refuses to start against a
database built at a different height, so changing it means deleting the node
and syncing again. Keep it at or below the height the wallet was created at —
a node that starts above the wallet can never show that wallet's older
transactions, and the balance simply reads low.

There is no snapshot import: this daemon has no `--import-lite-snapshot`, so a
new node syncs from the network.

See [LITENODE.md](../../LITENODE.md) for what a lite node does and does not
hold.

---

## Cross-platform notes

| Feature | Windows | Linux | macOS |
|---------|---------|-------|-------|
| Secure storage backend | DPAPI | libsecret / keyring | Keychain |
| File picker | ✓ | ✓ | ✓ |
| Window manager (min size / title) | ✓ | ✓ | ✓ |
| URL launcher | ✓ | ✓ | ✓ |

### Linux: system dependencies

```bash
sudo apt-get install libsecret-1-dev libjsoncpp-dev
```

---

## Still to do

- **Icons.** `assets/images/app_icon.ico` is the daemon's icon as a placeholder.
  A PNG is needed for `flutter_launcher_icons`.
- **Translations.** The eight non-English locales still describe WrkzCoin's
  address shape in `invalidWrkzAddress`; the English string is correct. The
  rest of the brand strings were updated mechanically and deserve a read by a
  speaker of each language.
- **Icons for the About links.** Bluesky, Reddit and Medium use the nearest
  Material glyph; proper brand icons would need an asset each.

---

## Project structure

```
lib/
├── app/               # App entry, router, MaterialApp
├── core/
│   ├── api/models/    # Balance, Transaction, WalletStatus
│   ├── auth/          # Wallet password storage
│   ├── config/        # Coin and default-node constants
│   ├── ffi/           # Dart FFI binding for wallet_capi
│   ├── node/          # Local lite node supervisor
│   └── providers/     # Riverpod providers + polling notifiers
├── features/          # One directory per screen
├── shared/            # Theme, formatters, shared widgets
└── main.dart
```
