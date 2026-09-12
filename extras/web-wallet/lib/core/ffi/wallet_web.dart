/// wallet_web.dart
///
/// Browser binding for the DeroGold wallet. Everything below goes through the
/// `DeroGoldWallet` object that `web/wallet_bridge.js` installs on the page:
/// the bridge owns the Web Worker, the WebAssembly module built from
/// `extras/web-wallet-wasm`, and the IndexedDB store the wallet file lives in.
/// No wallet work ever runs on the UI isolate.
///
/// The bridge surface is exactly six calls:
///
///   DeroGoldWallet.init({wasmUrl})      -> Promise<void>
///   DeroGoldWallet.call(method, json)   -> Promise<String>   (a JSON reply)
///   DeroGoldWallet.listWallets()        -> Promise<String[]>
///   DeroGoldWallet.loadWallet(name)     -> Promise<bool>     IndexedDB -> module
///   DeroGoldWallet.persistWallet(name)  -> Promise<bool>     module -> IndexedDB
///   DeroGoldWallet.deleteWallet(name)   -> Promise<bool>
///
/// `call` speaks the request protocol in
/// `extras/web-wallet-wasm/wasm/src/wallet_wasm_exports.cpp` and answers with
/// either `{"ok":true,"result":…}` or `{"ok":false,"error":…,"errorMessage":…}`.
///
/// Two rules come from the fact that the module's filesystem is in memory and
/// dies with the page:
///
///   * `loadWallet` must run before the "open" method, or the module has no
///     file to open.
///   * `persistWallet` must run after "save" and after "close", or the work
///     done since the last persist is lost when the tab goes away.
///
/// Both are handled here rather than left to callers.
///
/// This file deliberately has no counterpart for WrkzCoin's `syncStep`,
/// `sendPrepared` / `deletePrepared`, `getTransactionsStatusJson` or
/// `importSubwalletFromIndex`: this backend does not implement them. The
/// synchroniser runs on its own pthreads and needs no stepping, and a
/// transaction is built and relayed in the same call.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// ─── exception ────────────────────────────────────────────────────────────────

class WalletCApiException implements Exception {
  final int errorCode;
  final String message;
  WalletCApiException(this.errorCode, this.message);

  @override
  String toString() => 'WalletCApiException($errorCode): $message';
}

// ─── event types (match WALLET_EVENT_* in wallet_capi.h) ─────────────────────

enum WalletEvent {
  none(0),
  synced(1),
  transaction(2);

  final int value;
  const WalletEvent(this.value);

  static WalletEvent fromInt(int v) => WalletEvent.values
      .firstWhere((e) => e.value == v, orElse: () => WalletEvent.none);
}

// ─── the bridge object ────────────────────────────────────────────────────────

const String _kBridgeGlobal = 'DeroGoldWallet';

/// What `init` is pointed at. The emscripten glue beside it works out where
/// `wallet_wasm.wasm` and the pthread worker live, so this is the only path
/// the page has to know. Both files are emitted by the CMake `wallet_wasm`
/// target and copied into `web/`.
const String _kWasmUrl = 'wallet_wasm.js';

/// Loading the module is a few hundred milliseconds of network and compile on
/// a cold cache. A minute means it is never arriving, not that it is slow.
const Duration _kStartupTimeout = Duration(seconds: 60);

JSObject? get _bridgeOrNull {
  if (!globalContext.has(_kBridgeGlobal)) return null;
  return globalContext.getProperty<JSAny?>(_kBridgeGlobal.toJS) as JSObject?;
}

JSObject get _bridge {
  final b = _bridgeOrNull;
  if (b == null) {
    throw WalletCApiException(
      -1,
      'The wallet engine is not on this page. web/wallet_bridge.js did not '
      'load, or it loaded and threw — check the browser console. The usual '
      'cause is that the server is not sending the Cross-Origin-Opener-Policy '
      'and Cross-Origin-Embedder-Policy headers, without which the module '
      'cannot start its threads.',
    );
  }
  return b;
}

/// Extracts something readable out of whatever a rejected Promise threw.
String _describe(Object error) {
  if (error is WalletCApiException) return error.message;
  if (error is JSObject) {
    final message = error.getProperty<JSAny?>('message'.toJS);
    if (message != null) return message.dartify().toString();
  }
  if (error is JSAny) return error.dartify().toString();
  return error.toString();
}

/// Calls one method on the bridge and awaits the Promise it returns.
///
/// Everything comes back as `JSAny?` and is narrowed at the call site: a
/// rejected or absent value must reach the caller as a WalletCApiException
/// with the JS error's own message, not as a failed cast.
Future<JSAny?> _promise(String method, List<JSAny?> args) async {
  final result = _bridge.callMethodVarArgs<JSAny?>(method.toJS, args);
  if (result == null) {
    throw WalletCApiException(
        -1, '$_kBridgeGlobal.$method returned nothing — expected a Promise');
  }
  try {
    return await (result as JSPromise<JSAny?>).toDart;
  } on WalletCApiException {
    rethrow;
  } catch (e) {
    throw WalletCApiException(-1, _describe(e));
  }
}

// ─── main binding class ───────────────────────────────────────────────────────

/// Browser implementation of the wallet API.
///
/// The same shape as the desktop wallet's `WalletCApi`, minus the calls this
/// backend does not have, and with every method asynchronous — a browser
/// cannot block on a worker.
class WalletCApi {
  WalletCApi();

  bool _open = false;

  /// The wallet currently in module memory. Needed because persisting is
  /// addressed by name, and save/close are called from screens that only know
  /// "the open wallet".
  String? _openName;

  Future<void>? _initFuture;

  bool get isOpen => _open;

  String? get openName => _openName;

  /// Boots the worker and the module, once per page. Every call below waits on
  /// this, so nothing has to sequence it by hand.
  Future<void> init() {
    return _initFuture ??= _init().timeout(
      _kStartupTimeout,
      onTimeout: () => throw WalletCApiException(
        -1,
        'The wallet engine did not start within ${_kStartupTimeout.inSeconds}s. '
        'Check the browser console: the usual causes are wallet_wasm.js or '
        'wallet_wasm.wasm missing from the server, or the server not sending '
        'the Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy '
        'headers.',
      ),
    );
  }

  Future<void> _init() async {
    final options = JSObject();
    options.setProperty('wasmUrl'.toJS, _kWasmUrl.toJS);
    await _promise('init', [options]);
  }

  // --- the request protocol ---------------------------------------------------

  /// One `wallet_wasm_request`, decoded. Throws on `{"ok":false}`.
  Future<dynamic> _call(String method, [Map<String, dynamic>? params]) async {
    await init();
    final reply =
        await _promise('call', [method.toJS, jsonEncode(params ?? const {}).toJS]);

    final Map<String, dynamic> decoded;
    try {
      decoded =
          jsonDecode((reply as JSString).toDart) as Map<String, dynamic>;
    } catch (_) {
      throw WalletCApiException(-1, 'Malformed reply to "$method"');
    }

    if (decoded['ok'] != true) {
      final message = decoded['errorMessage'] as String? ?? 'unknown error';
      throw WalletCApiException(
          (decoded['error'] as num?)?.toInt() ?? -1, message);
    }
    return decoded['result'];
  }

  Future<Map<String, dynamic>> _callMap(String method,
      [Map<String, dynamic>? params]) async {
    final result = await _call(method, params);
    if (result is Map<String, dynamic>) return result;
    if (result is Map) return Map<String, dynamic>.from(result);
    return {};
  }

  Future<String> _callStr(String method, [Map<String, dynamic>? params]) async {
    final result = await _call(method, params);
    if (result == null) return '';
    return result is String ? result : jsonEncode(result);
  }

  Future<bool> _callBool(String method, [Map<String, dynamic>? params]) async {
    return await _call(method, params) == true;
  }

  Future<int> _callInt(String method, [Map<String, dynamic>? params]) async {
    final result = await _call(method, params);
    return (result as num?)?.toInt() ?? 0;
  }

  /// Best-effort fire-and-forget, for the setters called during startup while
  /// the module may still be loading. An unawaited Future that throws is an
  /// unhandled error, and losing a log level is never worth taking the app
  /// down for.
  void _fireAndForget(String method, [Map<String, dynamic>? params]) {
    _call(method, params).catchError((Object _) => null);
  }

  // --- browser storage --------------------------------------------------------

  /// Names of the wallets this browser holds. Available before any wallet is
  /// open, which is what the Open Wallet form needs.
  Future<List<String>> listWallets() async {
    await init();
    final names = await _promise('listWallets', const []);
    if (names == null) return const [];
    return (names as JSArray<JSString>).toDart.map((n) => n.toDart).toList();
  }

  Future<void> _loadFromStorage(String name) async {
    await init();
    await _promise('loadWallet', [name.toJS]);
  }

  Future<void> _persistToStorage(String name) async {
    await init();
    await _promise('persistWallet', [name.toJS]);
  }

  // --- version ---

  Future<int> apiVersion() => _callInt('apiVersion');
  Future<String> versionString() => _callStr('versionString');

  /// The module refuses to build without pthreads, so this is an assertion the
  /// page can make rather than a capability to branch on.
  Future<bool> isPthreadsEnabled() => _callBool('isPthreadsEnabled');

  // --- lifecycle ---

  Future<void> open(
    String filename,
    String password,
    String daemonHost,
    int daemonPort, {
    bool ssl = false,
    int syncThreads = 0,
  }) async {
    // The module's filesystem starts empty on every page load, so the file has
    // to be pushed in from IndexedDB before "open" can find it.
    await _loadFromStorage(filename);
    await _call('open', {
      'filename': filename,
      'password': password,
      'daemonHost': daemonHost,
      'daemonPort': daemonPort,
      'daemonSsl': ssl,
      'syncThreads': syncThreads,
    });
    _open = true;
    _openName = filename;
  }

  Future<void> create(
    String filename,
    String password,
    String daemonHost,
    int daemonPort, {
    bool ssl = false,
    int syncThreads = 0,
  }) async {
    await _call('create', {
      'filename': filename,
      'password': password,
      'daemonHost': daemonHost,
      'daemonPort': daemonPort,
      'daemonSsl': ssl,
      'syncThreads': syncThreads,
    });
    _open = true;
    _openName = filename;
    // A wallet that only exists in module memory is gone on refresh. Get it
    // into IndexedDB before the user is told it was created.
    await save();
  }

  Future<void> restoreFromSeed(
    String mnemonicSeed,
    String filename,
    String password,
    String daemonHost,
    int daemonPort, {
    int scanHeight = 0,
    bool ssl = false,
    int syncThreads = 0,
  }) async {
    await _call('restoreFromSeed', {
      'mnemonicSeed': mnemonicSeed,
      'filename': filename,
      'password': password,
      'scanHeight': scanHeight,
      'daemonHost': daemonHost,
      'daemonPort': daemonPort,
      'daemonSsl': ssl,
      'syncThreads': syncThreads,
    });
    _open = true;
    _openName = filename;
    await save();
  }

  Future<void> restoreFromKeys(
    String privateSpendKey,
    String privateViewKey,
    String filename,
    String password,
    String daemonHost,
    int daemonPort, {
    int scanHeight = 0,
    bool ssl = false,
    int syncThreads = 0,
  }) async {
    await _call('restoreFromKeys', {
      'privateSpendKey': privateSpendKey,
      'privateViewKey': privateViewKey,
      'filename': filename,
      'password': password,
      'scanHeight': scanHeight,
      'daemonHost': daemonHost,
      'daemonPort': daemonPort,
      'daemonSsl': ssl,
      'syncThreads': syncThreads,
    });
    _open = true;
    _openName = filename;
    await save();
  }

  Future<void> restoreViewWallet(
    String privateViewKey,
    String address,
    String filename,
    String password,
    String daemonHost,
    int daemonPort, {
    int scanHeight = 0,
    bool ssl = false,
    int syncThreads = 0,
  }) async {
    await _call('restoreViewWallet', {
      'privateViewKey': privateViewKey,
      'address': address,
      'filename': filename,
      'password': password,
      'scanHeight': scanHeight,
      'daemonHost': daemonHost,
      'daemonPort': daemonPort,
      'daemonSsl': ssl,
      'syncThreads': syncThreads,
    });
    _open = true;
    _openName = filename;
    await save();
  }

  /// Saves the wallet, then copies it out of module memory into IndexedDB.
  /// Without the second half the first half is invisible after a refresh.
  Future<void> save() async {
    final name = _openName;
    await _call('save');
    if (name != null && name.isNotEmpty) {
      await _persistToStorage(name);
    }
  }

  Future<void> close() async {
    final name = _openName;
    final wasOpen = _open;
    // Clear the flags before awaiting, not after. The close round trip goes
    // through IndexedDB, and if an open or restore completes while it is in
    // flight, setting _open = false afterwards would mark the *new* wallet
    // closed — every screen then reports "Wallet not connected" against a
    // wallet that is perfectly open.
    _open = false;
    _openName = null;
    if (!wasOpen) return;
    // "close" runs the wallet's final save into module memory; that still has
    // to be persisted, and it has to be persisted before the tab forgets it.
    await _call('close');
    if (name != null && name.isNotEmpty) {
      await _persistToStorage(name);
    }
  }

  Future<void> changePassword(String newPassword) async {
    await _call('changePassword', {'newPassword': newPassword});
    await save();
  }

  Future<String> exportJson() async {
    final result = await _call('exportJson');
    return result is String ? result : jsonEncode(result);
  }

  /// Removes a wallet from the module's filesystem and from IndexedDB. Both
  /// halves matter: deleting only one leaves the wallet reappearing in the
  /// Open Wallet list on the next page load.
  Future<void> deleteFile(String filename) async {
    await init();
    try {
      await _call('deleteFile', {'filename': filename});
    } on WalletCApiException {
      // Not in module memory this session — the copy in IndexedDB is the one
      // that matters, and it is deleted next.
    }
    await _promise('deleteWallet', [filename.toJS]);
    if (_openName == filename) {
      _open = false;
      _openName = null;
    }
  }

  // --- sync / node ---

  Future<Map<String, int>> getSyncStatus() async {
    final m = await _callMap('getSyncStatus');
    return {
      'walletHeight': (m['walletHeight'] as num?)?.toInt() ?? 0,
      'localDaemonHeight': (m['localDaemonHeight'] as num?)?.toInt() ?? 0,
      'networkHeight': (m['networkHeight'] as num?)?.toInt() ?? 0,
    };
  }

  Future<bool> isDaemonOnline() => _callBool('isDaemonOnline');

  Future<Map<String, dynamic>> getStatusJson() => _callMap('getStatusJson');

  Future<Map<String, dynamic>> getNodeInfoJson() => _callMap('getNodeInfoJson');

  Future<void> swapNode(String host, int port, {bool ssl = false}) async {
    await _call('swapNode', {
      'daemonHost': host,
      'daemonPort': port,
      'daemonSsl': ssl,
    });
  }

  Future<void> reset({int scanHeight = 0, int timestamp = 0}) async {
    await _call('reset', {'scanHeight': scanHeight, 'timestamp': timestamp});
  }

  // --- balances ---

  Future<({int unlocked, int locked})> getTotalBalance() async {
    final m = await _callMap('getTotalBalance');
    return (
      unlocked: (m['unlocked'] as num?)?.toInt() ?? 0,
      locked: (m['locked'] as num?)?.toInt() ?? 0,
    );
  }

  Future<int> getSpendableBalance() => _callInt('getSpendableBalance');

  Future<({int unlocked, int locked})> getBalanceForAddress(
      String address) async {
    final m = await _callMap('getBalanceForAddress', {'address': address});
    return (
      unlocked: (m['unlocked'] as num?)?.toInt() ?? 0,
      locked: (m['locked'] as num?)?.toInt() ?? 0,
    );
  }

  Future<Map<String, dynamic>> getBalancesJson() => _callMap('getBalancesJson');

  // --- addresses ---

  Future<String> getPrimaryAddress() => _callStr('getPrimaryAddress');

  Future<Map<String, dynamic>> getAddressesJson() =>
      _callMap('getAddressesJson');

  // --- transactions ---

  Future<Map<String, dynamic>> getTransactionsJson({
    int startHeight = 0,
    int endHeight = 0,
    bool includeUnconfirmed = true,
  }) {
    return _callMap('getTransactionsJson', {
      'startHeight': startHeight,
      'endHeight': endHeight,
      'includeUnconfirmed': includeUnconfirmed,
    });
  }

  Future<String> getTxPrivateKey(String txHash) =>
      _callStr('getTxPrivateKey', {'txHash': txHash});

  // --- send and sweep ---
  //
  // Both build *and* relay. There is no prepare-then-send pair here, so a
  // transaction's fee and ring size are only known once it is already on its
  // way — which is why the review step shows neither.

  Future<String> sendBasic(String destination, int amount,
      {String paymentId = ''}) {
    return _callStr('sendBasic', {
      'destination': destination,
      'amount': amount,
      'paymentId': paymentId,
    });
  }

  Future<Map<String, dynamic>> sendAdvanced(String requestJson) =>
      _callMap('sendAdvancedJson', {'requestJson': requestJson});

  Future<Map<String, dynamic>> sweepToAddress(String destination,
      {String paymentId = '', int amountToSweep = 0}) {
    return _callMap('sweepToAddress', {
      'destination': destination,
      'paymentId': paymentId,
      'amountToSweep': amountToSweep,
    });
  }

  Future<({int txCount, int totalFee})> estimateSweep(
      {int amountToSweep = 0}) async {
    final m = await _callMap('estimateSweep', {'amountToSweep': amountToSweep});
    return (
      txCount: (m['txCount'] as num?)?.toInt() ?? 0,
      totalFee: (m['totalFee'] as num?)?.toInt() ?? 0,
    );
  }

  // --- keys / seeds ---

  Future<String> getPrivateViewKey() => _callStr('getPrivateViewKey');

  Future<Map<String, dynamic>> getSpendKeysJson(String address) =>
      _callMap('getSpendKeysJson', {'address': address});

  Future<String> getMnemonicSeed() => _callStr('getMnemonicSeed');

  Future<String> getMnemonicSeedForAddress(String address) =>
      _callStr('getMnemonicSeedForAddress', {'address': address});

  Future<bool> isViewWallet() => _callBool('isViewWallet');

  // --- subwallets ---

  Future<Map<String, dynamic>> addSubwallet() => _callMap('addSubwallet');

  Future<String> importSubwalletFromKey(String privateSpendKeyHex,
      {int scanHeight = 0}) {
    return _callStr('importSubwalletFromKey', {
      'privateSpendKey': privateSpendKeyHex,
      'scanHeight': scanHeight,
    });
  }

  Future<void> deleteSubwallet(String address) async {
    await _call('deleteSubwallet', {'address': address});
  }

  // --- integrated address ---

  Future<String> createIntegratedAddress(String address, String paymentId) {
    return _callStr('createIntegratedAddress', {
      'address': address,
      'paymentId': paymentId,
    });
  }

  // --- events ---

  /// Drains one event. This is the only way sync progress and new transactions
  /// are announced — the module runs its synchroniser on its own threads and
  /// nothing here drives it — so something has to poll this on a timer. See
  /// `walletEventPumpProvider`.
  ///
  /// Returns null when the queue is empty.
  Future<({WalletEvent type, Map<String, dynamic> data})?> pollEvent(
      {int timeoutMs = 0}) async {
    final m = await _callMap('pollEvent', {'timeoutMs': timeoutMs});
    final type = WalletEvent.fromInt((m['eventType'] as num?)?.toInt() ?? 0);
    if (type == WalletEvent.none) return null;
    final data = m['eventData'];
    return (
      type: type,
      data: data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
    );
  }

  // --- logging ---

  /// Level names match `Logger::LogLevel`; the module takes the number.
  void setLogLevel(String levelName) {
    const nameToLevel = {
      'disabled': 0,
      'fatal': 1,
      'warning': 2,
      'info': 3,
      'debug': 4,
      'trace': 5,
    };
    _fireAndForget(
        'setLogLevel', {'level': nameToLevel[levelName.toLowerCase()] ?? 3});
  }

  Future<Map<String, dynamic>> takeLogs() => _callMap('takeLogsJson');

  void clearLogs() => _fireAndForget('clearLogs');

  // --- transaction PoW ---

  Future<({bool active, int elapsedMs, int nonces})> getPowStatus() async {
    final m = await _callMap('getPowStatus');
    return (
      active: m['active'] == true,
      elapsedMs: (m['elapsedMs'] as num?)?.toInt() ?? 0,
      nonces: (m['nonces'] as num?)?.toInt() ?? 0,
    );
  }

  void setScanCoinbase(bool scan) => _fireAndForget('setScanCoinbase', {'scan': scan});

  /// Routes transaction PoW through an external server, falling back to
  /// computing it in the worker. An empty host turns it off — which in a
  /// browser is the slow path, so it is worth having.
  void setTxPowServer(String host, int port, {bool ssl = false}) {
    _fireAndForget('setTxPowServer', {'host': host, 'port': port, 'ssl': ssl});
  }

  /// Checks a Tx PoW server without configuring it. Resolves to
  /// {ok, url, latency_ms, threads, queue, capacity}, or {ok: false, url, error}.
  Future<Map<String, dynamic>> testTxPowServer(String host, int port,
          {bool ssl = false}) =>
      _callMap('testTxPowServer', {'host': host, 'port': port, 'ssl': ssl});

  /// Probes a daemon without switching the wallet onto it. Resolves to
  /// {ok, url, latency_ms, height, networkHeight, peerCount, synced}, or
  /// {ok: false, url, error}.
  Future<Map<String, dynamic>> testNode(String host, int port,
          {bool ssl = false}) =>
      _callMap('testNode', {'host': host, 'port': port, 'ssl': ssl});
}
