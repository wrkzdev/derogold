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
const String kDefaultDaemonHost = 'dego-node-rpc.0z.network';
const int kDefaultDaemonPort = 6969;
const bool kDefaultDaemonSSL = false;

/// Transaction PoW server (see TXPOWSERVER.md), prefilled with the project's
/// public one.
///
/// The switch in Settings is **off** by default, so the wallet computes the
/// proof of work on this machine until someone turns it on — enabling it is
/// then one switch rather than three fields. Any other server can be entered
/// instead, and the wallet re-verifies every nonce it is given.
const String kDefaultTxPowServerHost = 'dego-txpow-rpc.0z.network';
const int kDefaultTxPowServerPort = 80;
const bool kDefaultTxPowServerSSL = false;

/// A rescan starting below this height walks most of the chain and takes hours
/// — worth a second question before it starts. The CLI wallet asks at the same
/// height (`WalletConfig::slowRescanHeight`).
const int kSlowRescanHeight = 2900000;

/// How often to poll the wallet via FFI for live updates.
const Duration kStatusPollInterval = Duration(seconds: 5);
const Duration kBalancePollInterval = Duration(seconds: 10);
const Duration kTransactionPollInterval = Duration(seconds: 15);
