/// App-wide constants, coin configuration, node presets, and general settings.
///
/// The coin values here match `src/config/CryptoNoteConfig.h` and
/// `src/config/WalletConfig.h` in this repository, and the desktop wallet's
/// `extras/desktop-wallet/lib/core/config/app_config.dart`.
class AppConfig {
  AppConfig._();

  // ── coin ───────────────────────────────────────────────────────────────────
  static const String ticker = 'DEGO';
  static const String coinName = 'DeroGold';
  static const int decimalPlaces = 2;
  static const int atomicDivisor = 100; // 10^decimalPlaces
  static const String addressPrefix = 'dg';

  /// Address shape. 97 = standard, 185 = integrated (a standard address with a
  /// 64-character payment ID folded in, base58-encoded in 11-character blocks).
  static const Set<int> validAddressLengths = {97, 185};

  /// Minimum wallet password length enforced on create / change.
  static const int minPasswordLength = 8;

  // ── node presets ───────────────────────────────────────────────────────────
  static const List<NodePreset> nodePresets = [
    NodePreset(
      label: 'DeroGold Primary',
      host: 'dego-node-rpc.0z.network',
      port: 6969,
      ssl: false,
    ),
  ];

  /// Default daemon shown in Create / Open / Import forms. 6969 is
  /// `RPC_DEFAULT_PORT`; point it at your own node if you run one.
  static const String defaultDaemonHost = 'dego-node-rpc.0z.network';
  static const int defaultDaemonPort = 6969;
  static const bool defaultDaemonSsl = false;

  /// Public transaction PoW server prefilled in Settings (see TXPOWSERVER.md).
  /// Off by default; the wallet computes the proof of work on the phone until
  /// the user enables it, so turning it on is one switch rather than three
  /// fields. The wallet re-verifies every nonce the server returns.
  static const String defaultTxPowServerHost = 'dego-txpow-rpc.0z.network';
  static const int defaultTxPowServerPort = 80;
  static const bool defaultTxPowServerSsl = false;

  /// A rescan starting below this height walks most of the chain and takes
  /// hours — worth a second question before it starts. The CLI wallet asks at
  /// the same height (`WalletConfig::slowRescanHeight`).
  static const int slowRescanHeight = 2900000;

  // ── polling intervals ──────────────────────────────────────────────────────
  static const Duration statusPollInterval = Duration(seconds: 5);
  static const Duration balancePollInterval = Duration(seconds: 10);
  static const Duration transactionsPollInterval = Duration(seconds: 15);

  // ── autosave ───────────────────────────────────────────────────────────────
  static const Duration autosaveInterval = Duration(minutes: 5);

  // ── auto-lock timeouts ─────────────────────────────────────────────────────
  static const List<AutoLockOption> autoLockOptions = [
    AutoLockOption(label: 'Immediately', duration: Duration.zero),
    AutoLockOption(label: '1 minute', duration: Duration(minutes: 1)),
    AutoLockOption(label: '5 minutes', duration: Duration(minutes: 5)),
    AutoLockOption(label: 'Never', duration: null),
  ];
  static const int defaultAutoLockIndex = 0; // Immediately

  // ── wallet file storage ────────────────────────────────────────────────────
  static const String walletsSubdir = 'wallets';
  static const String registryFilename = 'wallets.json';
  static const String walletFileExtension = '.wallet';

  // ── UI ─────────────────────────────────────────────────────────────────────
  static const int recentTxCount = 5;
  static const int historyPageSize = 25;

  // ── project links ──────────────────────────────────────────────────────────
  static const String appVersion = '1.0.0';
  static const String githubUrl = 'https://github.com/derogold/derogold-core';
  static const String websiteUrl = 'https://derogold.com/';
  static const String blueskyUrl =
      'https://bsky.app/profile/derogold.bsky.social';
  static const String twitterUrl = 'https://twitter.com/DeroGold';
  static const String redditUrl = 'https://reddit.com/r/DeroGold';
  static const String mediumUrl = 'https://medium.com/@DeroGold';

  // ── secure storage keys ────────────────────────────────────────────────────
  static const String skThemeMode = 'pref_theme_mode';
  static const String skNotificationsEnabled = 'pref_notifications';
  static const String skAutosaveEnabled = 'pref_autosave';
  static const String skAutoLockIndex = 'pref_auto_lock_index';
  static const String skBiometricEnabled = 'pref_biometric';
  static const String skSeedBackupConfirmed = 'pref_seed_backup_confirmed';
  static const String skLogLevel = 'pref_log_level';
  static const String skSkipCoinbase = 'pref_skip_coinbase';
  static const String skLocale = 'pref_locale';
  static const String skFirstLaunchDone = 'pref_first_launch_done';
  // Per-wallet password key: "wallet_pw_<filename>"
  static String walletPasswordKey(String filename) => 'wallet_pw_$filename';
}

class NodePreset {
  final String label;
  final String host;
  final int port;
  final bool ssl;

  const NodePreset({
    required this.label,
    required this.host,
    required this.port,
    required this.ssl,
  });
}

class AutoLockOption {
  final String label;

  /// null means "Never" (auto-lock disabled).
  final Duration? duration;

  const AutoLockOption({required this.label, required this.duration});
}
