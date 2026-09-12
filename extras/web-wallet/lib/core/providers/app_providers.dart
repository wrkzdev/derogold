import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/app_config.dart';
import '../ffi/wallet_web.dart';
import 'providers.dart';

/// On the web this is localStorage with a WebCrypto-wrapped value, so it holds
/// preferences and the password *verifier* — never the wallet file itself,
/// which lives in IndexedDB and is managed by the bridge.
const _storage = FlutterSecureStorage();
const _kThemeModeKey = 'derogold_theme_mode';
const _kLogLevelKey = 'derogold_log_level';
const _kNotificationsKey = 'derogold_notifications_enabled';
const _kLastWalletKey = 'derogold_last_wallet_name';

// ── Last-opened wallet ───────────────────────────────────────────────────────

/// The name of the wallet that was last opened, or null if none. The name is
/// the key the bridge stores it under in IndexedDB.
final lastWalletPathProvider = FutureProvider<String?>((ref) async {
  return _storage.read(key: _kLastWalletKey);
});

/// Records which wallet is open. Call on every successful open/create/restore.
Future<void> saveLastWalletPath(String name) async {
  await _storage.write(key: _kLastWalletKey, value: name);
}

/// Forgets the open wallet. Call on close.
Future<void> clearLastWalletPath() async {
  await _storage.delete(key: _kLastWalletKey);
}

// ── Theme mode ────────────────────────────────────────────────────────────────

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final v = await _storage.read(key: _kThemeModeKey);
    state = switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await _storage.write(
      key: _kThemeModeKey,
      value: switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      },
    );
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

// ── Log level ─────────────────────────────────────────────────────────────────

/// Maps to C++ Logger::LogLevel: DISABLED=0, FATAL=1, WARNING=2, INFO=3,
/// DEBUG=4, TRACE=5.
enum WalletLogLevel {
  disabled(0, 'Disabled'),
  fatal(1, 'Fatal only'),
  warning(2, 'Warnings'),
  info(3, 'Info'),
  debug(4, 'Debug'),
  trace(5, 'Trace');

  final int value;
  final String label;
  const WalletLogLevel(this.value, this.label);
}

class LogLevelNotifier extends Notifier<WalletLogLevel> {
  @override
  WalletLogLevel build() {
    _load();
    return WalletLogLevel.info;
  }

  Future<void> _load() async {
    final v = await _storage.read(key: _kLogLevelKey);
    final n = int.tryParse(v ?? '') ?? 3;
    state = WalletLogLevel.values.firstWhere(
      (l) => l.value == n,
      orElse: () => WalletLogLevel.info,
    );
    _applyToModule(state);
  }

  Future<void> set(WalletLogLevel level) async {
    state = level;
    _applyToModule(level);
    await _storage.write(key: _kLogLevelKey, value: level.value.toString());
  }

  /// The wallet library's logger starts DISABLED every time the module loads,
  /// so the stored preference has to be pushed across on load as well as on
  /// change. Without this the dropdown restores from browser storage while the
  /// library is still silent, and the log viewer tells you to set a level
  /// above Disabled — which you appear to have already done.
  void _applyToModule(WalletLogLevel level) {
    try {
      ref.read(walletCApiProvider).setLogLevel(level.name);
    } catch (_) {
      // Bridge not up yet, or not loadable at all — logging is best effort.
    }
  }
}

final logLevelProvider =
    NotifierProvider<LogLevelNotifier, WalletLogLevel>(LogLevelNotifier.new);

// ── Notifications preference ──────────────────────────────────────────────────

class NotificationsEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return true; // default: On
  }

  Future<void> _load() async {
    final v = await _storage.read(key: _kNotificationsKey);
    state = v != 'false';
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    await _storage.write(key: _kNotificationsKey, value: enabled.toString());
  }
}

final notificationsEnabledProvider =
    NotifierProvider<NotificationsEnabledNotifier, bool>(
        NotificationsEnabledNotifier.new);

// ── Autosave preference ──────────────────────────────────────────────────────

const _kAutosaveKey = 'derogold_autosave_enabled';

class AutosaveEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return true; // default: On
  }

  Future<void> _load() async {
    final v = await _storage.read(key: _kAutosaveKey);
    state = v != 'false';
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    await _storage.write(key: _kAutosaveKey, value: enabled.toString());
  }
}

final autosaveEnabledProvider =
    NotifierProvider<AutosaveEnabledNotifier, bool>(
        AutosaveEnabledNotifier.new);

// ── Scan coinbase ────────────────────────────────────────────────────────────

const _kScanCoinbaseKey = 'derogold_scan_coinbase';

class ScanCoinbaseNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false; // default: Off — coinbases are skipped, which syncs faster
  }

  Future<void> _load() async {
    final v = await _storage.read(key: _kScanCoinbaseKey);
    if (v != null) state = v == 'true';
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    await _storage.write(key: _kScanCoinbaseKey, value: enabled.toString());
  }
}

final scanCoinbaseProvider =
    NotifierProvider<ScanCoinbaseNotifier, bool>(ScanCoinbaseNotifier.new);

// ── External Tx PoW server ───────────────────────────────────────────────────

const _kTxPowServerKey = 'derogold_tx_pow_server';

/// Where the wallet sends its transaction proof of work. When [active], the
/// worker asks the server first and falls back to computing it in the browser
/// if the server does not answer — and a browser is by far the slowest place
/// to do it. Off by default, with the fields already pointing at the project's
/// public server, so enabling it is one switch rather than three fields.
class TxPowServerSettings {
  const TxPowServerSettings({
    this.enabled = false,
    this.host = kDefaultTxPowServerHost,
    this.port = kDefaultTxPowServerPort,
    this.ssl = kDefaultTxPowServerSSL,
    this.loaded = false,
  });

  final bool enabled;
  final String host;
  final int port;
  final bool ssl;

  /// True once the stored value has been read, so forms know when to prefill.
  final bool loaded;

  bool get active => enabled && host.isNotEmpty && port > 0;

  TxPowServerSettings copyWith({
    bool? enabled,
    String? host,
    int? port,
    bool? ssl,
    bool? loaded,
  }) =>
      TxPowServerSettings(
        enabled: enabled ?? this.enabled,
        host: host ?? this.host,
        port: port ?? this.port,
        ssl: ssl ?? this.ssl,
        loaded: loaded ?? this.loaded,
      );

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'host': host, 'port': port, 'ssl': ssl};

  factory TxPowServerSettings.fromJson(Map<String, dynamic> j) {
    final host = (j['host'] as String? ?? '').trim();
    return TxPowServerSettings(
      enabled: j['enabled'] as bool? ?? false,
      host: host.isEmpty ? kDefaultTxPowServerHost : host,
      port: (j['port'] as num?)?.toInt() ?? kDefaultTxPowServerPort,
      ssl: j['ssl'] as bool? ?? kDefaultTxPowServerSSL,
      loaded: true,
    );
  }

  /// Pushes this setting into the wallet worker. Call after every wallet open
  /// and whenever the setting changes.
  void applyTo(WalletCApi ffi) =>
      ffi.setTxPowServer(active ? host : '', port, ssl: ssl);
}

class TxPowServerNotifier extends Notifier<TxPowServerSettings> {
  @override
  TxPowServerSettings build() {
    _load();
    return const TxPowServerSettings();
  }

  Future<void> _load() async {
    final v = await _storage.read(key: _kTxPowServerKey);
    if (v == null || v.isEmpty) {
      state = state.copyWith(loaded: true);
      return;
    }
    try {
      state =
          TxPowServerSettings.fromJson(jsonDecode(v) as Map<String, dynamic>);
    } catch (_) {
      state = state.copyWith(loaded: true);
    }
  }

  Future<void> set(TxPowServerSettings settings) async {
    state = settings.copyWith(loaded: true);
    await _storage.write(
        key: _kTxPowServerKey, value: jsonEncode(settings.toJson()));
  }
}

final txPowServerProvider =
    NotifierProvider<TxPowServerNotifier, TxPowServerSettings>(
        TxPowServerNotifier.new);

// ── Wallet lock ───────────────────────────────────────────────────────────────

/// When true, the wallet is open but the UI is locked — a login screen is
/// shown. Set to true on lock, false after successful re-auth.
final walletLockedProvider = StateProvider<bool>((_) => false);

// ── Locale ───────────────────────────────────────────────────────────────────

const _kLocaleKey = 'derogold_locale';
const _kFirstLaunchDoneKey = 'derogold_first_launch_done';

const supportedLocales = [
  Locale('en'),
  Locale('fr'),
  Locale('de'),
  Locale('zh'),
  Locale('vi'),
  Locale('ja'),
  Locale('es'),
  Locale('pt'),
  Locale('ru'),
];

class LocaleNotifier extends Notifier<Locale?> {
  @override
  Locale? build() {
    _load();
    return null; // null = system default
  }

  Future<void> _load() async {
    final v = await _storage.read(key: _kLocaleKey);
    if (v != null && v.isNotEmpty) {
      state = Locale(v);
    }
  }

  Future<void> set(Locale? locale) async {
    state = locale;
    await _storage.write(key: _kLocaleKey, value: locale?.languageCode ?? '');
  }
}

final localeProvider =
    NotifierProvider<LocaleNotifier, Locale?>(LocaleNotifier.new);

// ── First launch flag ────────────────────────────────────────────────────────

final firstLaunchDoneProvider = FutureProvider<bool>((ref) async {
  final v = await _storage.read(key: _kFirstLaunchDoneKey);
  return v == 'true';
});

Future<void> markFirstLaunchDone() async {
  await _storage.write(key: _kFirstLaunchDoneKey, value: 'true');
}

// ── Default node preference ───────────────────────────────────────────────────

const _kDefaultNodeHostKey = 'derogold_default_node_host';
const _kDefaultNodePortKey = 'derogold_default_node_port';
const _kDefaultNodeSSLKey = 'derogold_default_node_ssl';

typedef DefaultNode = ({String host, int port, bool ssl});

class DefaultNodeNotifier extends Notifier<DefaultNode> {
  @override
  DefaultNode build() {
    _load();
    return (
      host: kDefaultDaemonHost,
      port: kDefaultDaemonPort,
      ssl: kDefaultDaemonSSL
    );
  }

  Future<void> _load() async {
    final host = await _storage.read(key: _kDefaultNodeHostKey);
    if (host == null) return;
    final portStr = await _storage.read(key: _kDefaultNodePortKey);
    final sslStr = await _storage.read(key: _kDefaultNodeSSLKey);
    state = (
      host: host,
      port: int.tryParse(portStr ?? '') ?? kDefaultDaemonPort,
      ssl: sslStr == 'true',
    );
  }

  Future<void> set(
      {required String host, required int port, required bool ssl}) async {
    state = (host: host, port: port, ssl: ssl);
    await _storage.write(key: _kDefaultNodeHostKey, value: host);
    await _storage.write(key: _kDefaultNodePortKey, value: port.toString());
    await _storage.write(key: _kDefaultNodeSSLKey, value: ssl.toString());
  }
}

final defaultNodeProvider =
    NotifierProvider<DefaultNodeNotifier, DefaultNode>(DefaultNodeNotifier.new);
