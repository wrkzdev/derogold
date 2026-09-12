/// Coin constants, matching src/config/CryptoNoteConfig.h and
/// src/config/WalletConfig.h in this repository.
const int kCoinDecimalPlaces = 2;
const String kCoinTicker = 'DEGO';
const String kCoinName = 'DeroGold';

/// Address shape. 97 = standard, 185 = integrated (a standard address with a
/// 64-character payment ID folded in, base58-encoded in 11-character blocks).
const String kAddressPrefix = 'dg';
const Set<int> kValidAddressLengths = {97, 185};

/// Minimum wallet password length enforced on create / change.
const int kMinPasswordLength = 8;

/// Default daemon shown in Create/Open/Import forms. 6969 is
/// `RPC_DEFAULT_PORT`; point it at your own node if you run one.
///
/// A browser will refuse to reach an http:// node from an https:// page, so a
/// wallet served over TLS needs either a TLS node or a same-origin reverse
/// proxy in front of one. See README.md.
const String kDefaultDaemonHost = 'dego-node-rpc.0z.network';
const int kDefaultDaemonPort = 6969;
const bool kDefaultDaemonSSL = false;

/// Transaction PoW server (see TXPOWSERVER.md), prefilled with the project's
/// public one.
///
/// The switch in Settings is **off** by default, so the wallet computes the
/// proof of work in this browser until someone turns it on — enabling it is
/// then one switch rather than three fields. Any other server can be entered
/// instead, and the wallet re-verifies every nonce it is given.
const String kDefaultTxPowServerHost = 'dego-txpow-rpc.0z.network';
const int kDefaultTxPowServerPort = 80;
const bool kDefaultTxPowServerSSL = false;

/// A rescan starting below this height walks most of the chain and takes hours
/// — worth a second question before it starts. The CLI wallet asks at the same
/// height (`WalletConfig::slowRescanHeight`).
const int kSlowRescanHeight = 2900000;

/// How often to poll the wallet module for live updates.
const Duration kStatusPollInterval = Duration(seconds: 5);
const Duration kBalancePollInterval = Duration(seconds: 10);
const Duration kTransactionPollInterval = Duration(seconds: 15);

/// How often to drain the module's event queue.
///
/// This is the only channel sync progress and new transactions arrive on —
/// the module synchronises on its own threads and cannot call back into Dart
/// — so it is polled far more often than the reads above, which it triggers.
/// An empty poll costs one message to the worker and nothing else.
const Duration kEventPollInterval = Duration(seconds: 1);

/// The most events one drain may take before letting the isolate go. A wallet
/// meeting its whole history queues them faster than any timer empties them,
/// and an unbounded loop would hold the UI for as long as that lasts.
const int kMaxEventsPerDrain = 32;
