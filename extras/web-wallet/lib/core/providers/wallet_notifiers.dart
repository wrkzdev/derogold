import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/models/balance.dart';
import '../api/models/wallet_status.dart';
import '../api/models/transaction.dart';
import '../config/app_config.dart';
import '../ffi/wallet_web.dart';
import 'providers.dart';

// ── Wallet session ────────────────────────────────────────────────────────────

/// Starts a new wallet session: drops every wallet-scoped cache so nothing
/// from the previous wallet can be shown against the new one.
///
/// Call after each successful open/create/restore, and after a close. The
/// providers below all watch [walletSessionProvider], so bumping it rebuilds
/// them — which also cancels and restarts their poll timers.
void beginWalletSession(WidgetRef ref, {String? walletName}) {
  ref.read(openWalletNameProvider.notifier).state = walletName;
  ref.read(walletSessionProvider.notifier).state++;
}

// ── Status polling ────────────────────────────────────────────────────────────

class StatusNotifier extends AsyncNotifier<WalletStatus> {
  Timer? _timer;

  @override
  Future<WalletStatus> build() async {
    ref.watch(walletSessionProvider);
    ref.onDispose(() => _timer?.cancel());
    _timer = Timer.periodic(kStatusPollInterval, (_) => _refresh());
    return _fetch();
  }

  Future<WalletStatus> _fetch() async {
    final ffi = ref.read(walletCApiProvider);
    if (!ffi.isOpen) throw Exception('Wallet not connected');
    final json = await ffi.getStatusJson();
    return WalletStatus.fromJson(json);
  }

  Future<void> _refresh() async {
    state = await AsyncValue.guard(_fetch);
  }

  Future<void> refresh() => _refresh();
}

final statusProvider =
    AsyncNotifierProvider<StatusNotifier, WalletStatus>(StatusNotifier.new);

// ── Balance polling ───────────────────────────────────────────────────────────

class BalanceNotifier extends AsyncNotifier<Balance> {
  Timer? _timer;

  @override
  Future<Balance> build() async {
    ref.watch(walletSessionProvider);
    ref.onDispose(() => _timer?.cancel());
    _timer = Timer.periodic(kBalancePollInterval, (_) => _refresh());
    return _fetch();
  }

  Future<Balance> _fetch() async {
    final ffi = ref.read(walletCApiProvider);
    if (!ffi.isOpen) throw Exception('Wallet not connected');
    final (:unlocked, :locked) = await ffi.getTotalBalance();
    return Balance(unlocked: unlocked, locked: locked);
  }

  Future<void> _refresh() async {
    state = await AsyncValue.guard(_fetch);
  }

  Future<void> refresh() => _refresh();
}

final balanceProvider =
    AsyncNotifierProvider<BalanceNotifier, Balance>(BalanceNotifier.new);

// ── Transaction list ──────────────────────────────────────────────────────────

class TransactionsNotifier extends AsyncNotifier<List<Transaction>> {
  Timer? _timer;

  @override
  Future<List<Transaction>> build() async {
    ref.watch(walletSessionProvider);
    ref.onDispose(() => _timer?.cancel());
    _timer = Timer.periodic(kTransactionPollInterval, (_) => _refresh());
    return _fetch();
  }

  Future<List<Transaction>> _fetch() async {
    final ffi = ref.read(walletCApiProvider);
    if (!ffi.isOpen) return [];
    final json = await ffi.getTransactionsJson(includeUnconfirmed: true);
    final confirmed = (json['transactions'] as List<dynamic>? ?? [])
        .map((t) => Transaction.fromJson(t as Map<String, dynamic>))
        .toList();
    final unconfirmed =
        (json['unconfirmedTransactions'] as List<dynamic>? ?? [])
            .map((t) => Transaction.fromJson(t as Map<String, dynamic>))
            .toList();
    // Show unconfirmed (mempool) first, then confirmed most-recent-first
    return [...unconfirmed, ...confirmed.reversed];
  }

  Future<void> _refresh() async {
    state = await AsyncValue.guard(_fetch);
  }

  Future<void> refresh() => _refresh();
}

final transactionsProvider =
    AsyncNotifierProvider<TransactionsNotifier, List<Transaction>>(
        TransactionsNotifier.new);

// ── Node info ─────────────────────────────────────────────────────────────────

class NodeInfoNotifier extends AsyncNotifier<Map<String, dynamic>> {
  Timer? _timer;

  @override
  Future<Map<String, dynamic>> build() async {
    ref.watch(walletSessionProvider);
    ref.onDispose(() => _timer?.cancel());
    _timer = Timer.periodic(kStatusPollInterval, (_) => _refresh());
    return _fetch();
  }

  Future<Map<String, dynamic>> _fetch() async {
    final ffi = ref.read(walletCApiProvider);
    if (!ffi.isOpen) return {};
    return ffi.getNodeInfoJson();
  }

  Future<void> _refresh() async {
    state = await AsyncValue.guard(_fetch);
  }

  Future<void> refresh() => _refresh();
}

final nodeInfoProvider =
    AsyncNotifierProvider<NodeInfoNotifier, Map<String, dynamic>>(
        NodeInfoNotifier.new);

// ── Event pump ────────────────────────────────────────────────────────────────

/// Drains the module's event queue.
///
/// This backend has no callback into Dart and no `syncStep` to drive from a
/// timer: the synchroniser runs on the module's own pthreads and announces
/// what it did by queueing events. `pollEvent` is the only way to hear about
/// them, so something has to ask — that is this.
///
/// The timer is short because the call itself is cheap and returns immediately
/// when the queue is empty; the poll intervals in app_config still bound how
/// often the heavier status/balance/transaction reads happen, since an event
/// is what triggers those rather than the clock alone.
class WalletEventPump extends Notifier<WalletEvent> {
  Timer? _timer;
  bool _draining = false;

  @override
  WalletEvent build() {
    ref.watch(walletSessionProvider);
    ref.onDispose(() => _timer?.cancel());
    _timer = Timer.periodic(kEventPollInterval, (_) => _drain());
    return WalletEvent.none;
  }

  Future<void> _drain() async {
    // One drain at a time. Each poll is a round trip to the worker, and
    // overlapping them stacks requests on a queue that is already the thing
    // under load.
    if (_draining) return;
    final ffi = ref.read(walletCApiProvider);
    if (!ffi.isOpen) return;
    _draining = true;
    try {
      // Bounded: a wallet meeting its whole history can queue events faster
      // than any timer drains them, and an unbounded loop here would hold the
      // isolate for as long as that lasts.
      for (var i = 0; i < kMaxEventsPerDrain; i++) {
        final event = await ffi.pollEvent();
        if (event == null) break;
        _apply(event.type);
      }
    } catch (_) {
      // A closed or half-open wallet — the next tick tries again.
    } finally {
      _draining = false;
    }
  }

  void _apply(WalletEvent type) {
    state = type;
    switch (type) {
      case WalletEvent.transaction:
        ref.read(balanceProvider.notifier).refresh();
        ref.read(transactionsProvider.notifier).refresh();
      case WalletEvent.synced:
        ref.read(statusProvider.notifier).refresh();
        ref.read(balanceProvider.notifier).refresh();
      case WalletEvent.none:
        break;
    }
  }
}

final walletEventPumpProvider =
    NotifierProvider<WalletEventPump, WalletEvent>(WalletEventPump.new);
