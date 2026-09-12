# DeroGold Wallet — web

A Flutter wallet for DeroGold that runs entirely in the browser. There is no
server side: the same wallet backend the desktop and CLI wallets use is compiled
to WebAssembly (`extras/web-wallet-wasm`), runs in a Web Worker, and keeps its
wallet file in this origin's IndexedDB. Keys never leave the tab.

> ## The page will not start without COOP/COEP
>
> The wallet module is built **with pthreads** — its synchroniser runs on real
> threads and has no single-step mode to drive from a timer. Threads in
> WebAssembly need `SharedArrayBuffer`, and a browser only grants that to a
> **cross-origin isolated** page.
>
> The server must send, on the HTML document:
>
> ```
> Cross-Origin-Opener-Policy: same-origin
> Cross-Origin-Embedder-Policy: require-corp
> ```
>
> No `<meta>` tag can substitute for them. Without both headers
> `self.crossOriginIsolated` is false, the module refuses to start, and
> `index.html` puts a banner on the page saying exactly this. An nginx block is
> [below](#serving-it).

---

## Requirements

| Tool | Version |
|------|---------|
| Flutter | 3.38.7+ |
| Dart | 3.10.7+ |
| Emscripten | 3.1.50+ (`emsdk`) |
| CMake | 3.15+ |

---

## Quick start

### 1. Build the WebAssembly module

From the repository root, with an activated emsdk on `PATH`:

```bash
emcmake cmake -S . -B build-wasm \
    -D CMAKE_BUILD_TYPE=Release \
    -D DEROGOLD_BUILD_WALLET_WASM=ON \
    -D DEROGOLD_WASM_PTHREADS=ON
cmake --build build-wasm --target wallet_wasm
```

### 2. Copy the artifacts into `web/`

`flutter build web` neither builds nor fetches them; it copies whatever is in
`web/` into the bundle verbatim. These files must already be there:

| File | Where it comes from |
|------|---------------------|
| `web/wallet_wasm.js` | `build-wasm/src/wallet_wasm.js` — the emscripten glue |
| `web/wallet_wasm.wasm` | `build-wasm/src/wallet_wasm.wasm` — the module |
| `web/wallet_wasm.worker.js` | `build-wasm/src/wallet_wasm.worker.js` — the pthread worker bootstrap, **if your Emscripten emits one** (newer versions inline it into the glue) |
| `web/wallet_bridge.js` | `extras/web-wallet-wasm/wasm/js/` |
| `web/wallet_storage.js` | `extras/web-wallet-wasm/wasm/js/` |
| `web/wallet_worker.js` | `extras/web-wallet-wasm/wasm/js/` |

```bash
cp build-wasm/src/wallet_wasm.js   extras/web-wallet/web/
cp build-wasm/src/wallet_wasm.wasm extras/web-wallet/web/
[ -f build-wasm/src/wallet_wasm.worker.js ] && \
  cp build-wasm/src/wallet_wasm.worker.js extras/web-wallet/web/
cp extras/web-wallet-wasm/wasm/js/wallet_{bridge,storage,worker}.js \
   extras/web-wallet/web/
```

The names are load-bearing: the glue asks the server for the `.wasm` by the name
it was linked under, so the pair cannot be renamed after the fact.

`scripts/docker/container-build.sh web` does all of the above, plus the Flutter
build and the packaging, in one command.

### 3. Build the Flutter bundle

```bash
cd extras/web-wallet
flutter pub get
flutter build web --release
```

**Output: `extras/web-wallet/build/web/`** — a static directory. Everything in
`web/` is copied into it alongside `index.html`, `flutter_bootstrap.js`,
`main.dart.js` and the asset bundle.

For a development run, `flutter run -d chrome` will **not** work on its own:
Flutter's dev server does not send COOP/COEP, so the module cannot start. Build
the release bundle and serve it behind a server that does, or put a proxy in
front of `flutter run --web-port` that adds the two headers.

---

## Serving it

Static files, over HTTPS, with the two isolation headers on the document.

```nginx
server {
    listen 443 ssl http2;
    server_name wallet.derogold.com;

    root /srv/derogold-web-wallet;   # the contents of build/web
    index index.html;

    # Without these two the wallet module cannot start its threads, and the
    # page says so instead of loading.
    add_header Cross-Origin-Opener-Policy   "same-origin"   always;
    add_header Cross-Origin-Embedder-Policy "require-corp"  always;
    # Lets the isolated document load its own subresources.
    add_header Cross-Origin-Resource-Policy "same-origin"   always;

    # nginx does not know this one out of the box, and a .wasm served as
    # application/octet-stream will not stream-compile.
    types { application/wasm wasm; }

    location / {
        try_files $uri $uri/ /index.html;
    }

    # The module is a few megabytes and changes only when it is rebuilt.
    location ~* \.(wasm|js)$ {
        expires 1h;
        add_header Cross-Origin-Opener-Policy   "same-origin"   always;
        add_header Cross-Origin-Embedder-Policy "require-corp"  always;
        add_header Cross-Origin-Resource-Policy "same-origin"   always;
    }
}
```

`add_header` does not inherit into a `location` that declares its own, which is
why the block above repeats them. Check the result with:

```bash
curl -sI https://wallet.derogold.com/ | grep -i cross-origin
```

and, in the page's console, `self.crossOriginIsolated` — it must be `true`.

### The node has to be reachable from the browser

A page served over HTTPS cannot open a plain HTTP connection; the browser blocks
it as mixed content, silently as far as the wallet is concerned. Either point
the wallet at a node that serves HTTPS, or proxy one on this same origin:

```nginx
    location /daemon/ {
        proxy_pass http://127.0.0.1:6969/;
        add_header Cross-Origin-Resource-Policy "same-origin" always;
    }
```

The default in [lib/core/config/app_config.dart](lib/core/config/app_config.dart)
is `dego-node-rpc.0z.network:6969` without TLS, which works when the wallet
itself is served over plain HTTP and needs one of the two arrangements above
otherwise.

---

## Where the wallet lives

| | |
|---|---|
| Wallet file | IndexedDB, on this origin, keyed by the name you gave it |
| Module filesystem | in memory, and gone when the tab closes |
| Preferences, password verifier | `localStorage` via `flutter_secure_storage` |

`wallet_bridge.js` moves the file between the two: `loadWallet(name)` before the
module opens it, `persistWallet(name)` after every save and after close. The Dart
binding does both halves inside `open()`, `save()` and `close()`, so nothing in
the UI has to remember.

**Clearing site data deletes the wallet.** So does a private window closing, and
so can a browser reclaiming storage under pressure. The setup screen says this
on the backup step; the seed phrase is the only copy that survives. Autosave
(Settings, on by default) writes back after the first full sync and every five
minutes after that.

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
| `kSlowRescanHeight` | `2900000` | below this, a rescan or an import asks for confirmation first |
| `kDefaultTxPowServerHost` | `dego-txpow-rpc.0z.network` | port 80, no SSL; the switch is still off by default |
| `kEventPollInterval` | 1 s | how often the module's event queue is drained |

Node address, theme and log level can be changed from **Settings** at runtime,
and from the gear icon on the setup screen before any wallet is open.

---

## Features

- **Overview** — balance (unlocked / locked), sync status, recent transactions
- **Receive** — primary address + QR code, integrated address generator with payment ID
- **Transfer** — a single validate → review → send flow, plus a sweep that
  consolidates every output into one transaction
- **History** — filter, search, paginated, expandable details
- **Address Book** — saved addresses with labels and notes
- **Settings** — node switch with a **Test** button, rescan, JSON export as a
  browser download, theme, log level, delete wallet
- **Lock** — saves, persists to IndexedDB and closes, returning to setup
- Nine languages, and a layout that collapses to a drawer below 600 px

### The send flow has two steps, not three

This backend builds and relays a transaction in one call — there is no
prepare-then-confirm pair behind it. So the review step confirms what you asked
for (address, amount, payment ID) and nothing more: the **fee and the ring size
are not known until the transaction has actually been sent**, and they are shown
on the success screen rather than guessed at on the review screen.

### Transaction PoW

Every DeroGold transaction carries a proof of work. In a browser that is the
slowest place it could possibly be computed — a send can sit for a minute or
more. Settings has a **Transaction PoW Server** section that hands the work to a
`DeroGold-txpow-server` instead. The switch is **off by default**, with the
fields prefilled with the project's public server, so enabling it is one switch.
The wallet re-verifies every nonce a server returns and falls back to the worker
if anything is wrong, so a bad server only ever costs time. See
[TXPOWSERVER.md](../../TXPOWSERVER.md).

### Rescanning

A rescan from far down the chain re-checks every block from there to the tip, in
one browser tab. Below `kSlowRescanHeight` both the Settings dialog and the
import forms say so and make you confirm before starting.

---

## What this backend does not have

`extras/web-wallet-wasm/wasm/src/wallet_wasm_exports.cpp` is the authoritative
method list, and it is narrower than WrkzCoin's. There is deliberately no Dart
code for any of these, not even a stub:

| Absent | Consequence |
|--------|-------------|
| `syncStep` | nothing drives the sync from a timer; the module's own threads do it, and `pollEvent` is how the UI hears about progress |
| `sendPrepared` / `deletePrepared` | the transfer screen is validate → review → send, with fee and ring size reported afterwards |
| `getTransactionsStatusJson` | transaction state comes from `getTransactionsJson` and the event queue |
| `importSubwalletFromIndex` | subwallets are imported by private spend key |

---

## Project structure

```
lib/
├── app/               # App entry, router, MaterialApp
├── core/
│   ├── api/models/    # Balance, Transaction, WalletStatus
│   ├── auth/          # PBKDF2 password verifier for the lock screen
│   ├── config/        # Coin and default-node constants
│   ├── ffi/           # dart:js_interop binding to the DeroGoldWallet bridge
│   └── providers/     # Riverpod providers, poll timers and the event pump
├── features/          # One directory per screen
├── shared/            # Theme, formatters, shared widgets
└── main.dart

web/
├── index.html         # COOP/COEP check, loads wallet_bridge.js
├── manifest.json
├── favicon.ico
├── wallet_bridge.js   # installs globalThis.DeroGoldWallet  ─┐
├── wallet_worker.js   # the Web Worker running the module    ├─ not built here
├── wallet_storage.js  # IndexedDB                            │
├── wallet_wasm.js     # emscripten glue                      │
└── wallet_wasm.wasm   # the module                          ─┘
```

---

## Still to do

- **Icons.** `web/favicon.ico` and `assets/images/app_icon.ico` are the daemon's
  icon as a placeholder. PWA icons (`web/icons/Icon-*.png`) are not present, so
  `manifest.json` only advertises the favicon.
- **Translations.** The brand strings were updated mechanically across the nine
  locales and deserve a read by a speaker of each language.
- **Icons for the About links.** Bluesky, Reddit and Medium use the nearest
  Material glyph; proper brand icons would need an asset each.

---

## Licence

GPL-3.0, as the rest of this repository. See [LICENSE](../../LICENSE).
