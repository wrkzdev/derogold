# DeroGold Wallet (mobile)

The DeroGold (DEGO) mobile wallet for Android, written in Flutter and talking
to this repository's `wallet_capi` native library over `dart:ffi`.

It is the phone counterpart to `extras/desktop-wallet/` and shares that app's
configuration, FFI binding and screen layout. Where the two differ, it is
because a phone differs: biometric unlock, auto-lock, QR scanning, local
notifications, and no embedded node.

| | |
|---|---|
| Package / application ID | `com.derogold.wallet` |
| Flutter package name | `derogold_wallet` |
| Version | 1.0.0+1 |
| Ticker | DEGO, 2 decimal places |
| Address prefix | `dg` (97 characters; 185 when integrated) |
| Default node | `dego-node-rpc.0z.network:6969`, non-SSL |
| Default Tx PoW server | `dego-txpow-rpc.0z.network:80`, non-SSL, **off** by default |
| Licence | GPL-3.0 — see `LICENSE` at the root of this repository |

## Building the native library

The app will not start without `libwallet_capi.so`. Build it from the root of
this repository once per ABI, with the Android NDK toolchain.

bionic has no `getcontext`/`swapcontext`/`makecontext`, which the wallet's fibre
dispatcher needs, so libucontext has to be built first — once per ABI, into its
own prefix:

```bash
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/<version>
bash scripts/build-libucontext-android.sh arm64-v8a x86_64
# -> build-android/libucontext/<abi>/{include,lib/libucontext.a}
```

Then the wallet library itself:

```bash
for ABI in arm64-v8a x86_64; do
  cmake -S . -B build-android-$ABI \
    -D CMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
    -D ANDROID_ABI=$ABI \
    -D ANDROID_PLATFORM=android-24 \
    -D CMAKE_BUILD_TYPE=Release \
    -D DEROGOLD_BUILD_WALLET_CAPI=ON \
    -D DEROGOLD_ANDROID_PROFILE=ON \
    -D LIBUCONTEXT_ROOT="$PWD/build-android/libucontext/$ABI"
  cmake --build build-android-$ABI --target wallet_capi -j"$(nproc)"
done
```

`DEROGOLD_ANDROID_PROFILE=ON` is the Android build profile: it forces
`DEROGOLD_BUILD_EXECUTABLES=OFF`, leaving just the wallet backend and its
dependencies — the daemon and the CLI tools need RocksDB and a P2P stack that
cannot be built for Android here.

It also leaves `DEROGOLD_ANDROID_DISABLE_OPENSSL=ON`: the NDK ships no OpenSSL,
so cpp-httplib has no TLS and the wallet reaches its node over plain HTTP. That
is why the node and Tx PoW defaults above are both non-SSL, and why ticking SSL
in Settings against this build will not connect.

`ANDROID_PLATFORM=android-24` matches `minSdk` in `android/app/build.gradle`;
building against a lower API than the app declares produces a library that links
but will not load on some devices.

### Where the `.so` files go

Gradle picks up native libraries from the app module's `jniLibs` directory, one
directory per ABI, named exactly as the ABI:

```
extras/mobile-wallet/android/app/src/main/jniLibs/arm64-v8a/libwallet_capi.so
extras/mobile-wallet/android/app/src/main/jniLibs/x86_64/libwallet_capi.so
```

That is the path a container build has to write to. The ABI list is fixed in
two places and both must agree with what is on disk: `abiFilters` in
`android/app/build.gradle`, and the directory names above. An ABI listed in
`abiFilters` with no `.so` behind it produces an app that installs and then
fails at the first wallet call.

`armeabi-v7a` is deliberately excluded — 32-bit ARM cannot address the memory a
sync needs, and packaging a library there would only produce installs that
crash.

**The whole `jniLibs/` tree is gitignored** — the repository root ignores
`extras/*/android/app/src/main/jniLibs/`, so neither the libraries nor the ABI
directories are tracked. A container build must create them:

```bash
for ABI in arm64-v8a x86_64; do
  mkdir -p extras/mobile-wallet/android/app/src/main/jniLibs/$ABI
  cp build-android-$ABI/src/libwallet_capi.so \
     extras/mobile-wallet/android/app/src/main/jniLibs/$ABI/
done
```

## Building the app

```bash
cd extras/mobile-wallet
flutter pub get
flutter gen-l10n          # only if you edit lib/l10n/*.arb
flutter run               # connected device or emulator
```

Gradle tasks, run from `extras/mobile-wallet/android` (or via `flutter build`,
which wraps them):

| Output | Gradle task | Flutter equivalent |
|---|---|---|
| Debug APK | `:app:assembleDebug` | `flutter build apk --debug` |
| Release APK | `:app:assembleRelease` | `flutter build apk --release` |
| Debug AAB | `:app:bundleDebug` | `flutter build appbundle --debug` |
| Release AAB | `:app:bundleRelease` | `flutter build appbundle --release` |

Artefacts land in `build/app/outputs/flutter-apk/` and
`build/app/outputs/bundle/<variant>/`.

### Toolchain versions

Flutter enforces a minimum for each of these and refuses to apply its Gradle
plugin below it, so they move as a set when Flutter does:

| Where | Version | Set by |
|---|---|---|
| `android/gradle/wrapper/gradle-wrapper.properties` | Gradle 8.14 | Flutter's floor |
| `android/settings.gradle` | AGP 8.11.1 | Flutter's floor |
| `android/settings.gradle` | Kotlin 2.2.20 | Flutter's floor |

The Flutter version itself is pinned elsewhere: `extras/desktop-wallet` and
`extras/web-wallet` ask for Dart `^3.10.7`, which requires Flutter 3.47.4,
which sets the three floors above. Raising any one of them alone is usually
wrong - check the others first.

AGP stays on 8.x deliberately. From AGP 9 only the new DSL is read, and the
Flutter Gradle plugin this app applies fails against it.

Running Gradle directly needs `android/local.properties` with `flutter.sdk`
(and `sdk.dir` on a machine where `ANDROID_HOME` is not set). It is gitignored,
so a container build must write it.

### Release signing

`android/app/build.gradle` reads the release key from `android/key.properties`
if that file exists, and otherwise from the environment:

```
DEROGOLD_KEYSTORE           # path to the .jks / .keystore
DEROGOLD_KEYSTORE_PASSWORD
DEROGOLD_KEY_ALIAS
DEROGOLD_KEY_PASSWORD
```

**If none of those are set, `assembleRelease` falls back to the debug keystore**
and logs that it did. The result installs and runs, which is what you want for
a test build, but it is not publishable: Play and every update path need a real,
stable key. No keystore is committed to this repository.

## Wallet storage

Wallet files live in the app's internal documents directory, which Android
backup and device transfer are both excluded from
(`android/app/src/main/res/xml/data_extraction_rules.xml`) — a wallet file is
spend-capable, and a restored keystore entry cannot be decrypted anyway.

```
<app_docs>/wallets/
├── wallets.json              # registry: captions, filenames, metadata
├── main_wallet.wallet        # wallet data
├── main_wallet.wallet.keys   # wallet keys
└── ...
```

Wallets are identified by caption ("Main Wallet", "Savings"); captions are
sanitised into safe filenames internally. If `wallets.json` is lost or corrupt,
the registry rebuilds itself from the `*.wallet` files it finds.

## Features

- Create, import (seed / keys / view-only), and manage multiple wallets
- Live sync against a configurable node, with a test button that probes a node
  before switching onto it
- Send with QR scanning and a review step; sweep-all for consolidating inputs
- Receive with a QR code, sharing, and integrated-address generation
- Transaction history with search and direction filters
- Transaction PoW offloaded to a server, optionally (Settings → Transaction PoW
  Server); off by default, so the phone computes it
- Biometric unlock, auto-lock on background or idle, `FLAG_SECURE` throughout
- Incoming-transaction notifications, light / dark / system theme, 9 languages

## What this wallet cannot do, and why

The wallet backend behind `include/walletcapi/wallet_capi.h` is narrower than
some other CryptoNote forks', and the app is shaped by that rather than around
it:

- **No prepared transactions.** `wallet_send_advanced_json` builds and relays a
  transaction in one call; there is no "build it, show me, then broadcast"
  pair. So the review step confirms the address, amount and payment ID, and the
  fee and ring size appear on the **success** screen, where they are first
  known. Any figure shown earlier would be a guess.
- **No embedded node.** There is no daemon on the phone and no lite-node
  snapshot import. Point the wallet at a node you run, or at the default above.
- **A rescan below block 2,900,000** walks most of the chain and takes hours on
  a phone, so Settings asks twice before starting one.

A node that holds only part of the chain (pruned, or running in lite mode)
reports a `pruneFloor`, and the app shows a standing notice naming the lowest
block that node can answer for — on every tab, and including when the wallet
reports itself synced, which is exactly when a balance missing its older half
looks most trustworthy. If the daemon says outright why it will not serve
blocks, that sentence is shown verbatim instead. See `LITENODE.md`.

## Branding assets

`assets/images/app_icon.png` and `android/app/src/main/res/mipmap-*/ic_launcher.png`
are still the placeholder raster icons inherited from the upstream app and need
replacing with DeroGold artwork before any public release. Nothing in the code
depends on their contents.
