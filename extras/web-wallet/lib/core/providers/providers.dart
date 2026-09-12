import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../ffi/wallet_web.dart';

// ── wallet binding ────────────────────────────────────────────────────────────

/// The page's single wallet binding. Everything it does goes through the
/// `DeroGoldWallet` bridge in `web/wallet_bridge.js`, which owns the worker
/// running the WebAssembly module.
final walletCApiProvider = Provider<WalletCApi>((_) => WalletCApi());

// ── Wallet open state ─────────────────────────────────────────────────────────

/// True once a wallet has been opened/created/restored successfully.
final walletOpenProvider = StateProvider<bool>((ref) => false);

// ── Wallet session ────────────────────────────────────────────────────────────

/// Bumped every time the wallet behind [walletCApiProvider] changes — after a
/// successful open/create/restore, and after a close.
///
/// Everything that reads wallet-specific data has to depend on this. The page
/// is never reloaded between wallets: closing one only flips
/// [walletOpenProvider] and routes back to /setup, so the root ProviderScope
/// and every non-autoDispose provider in it survive. Without a session key a
/// cached value from the previous wallet is served to the next one — which is
/// exactly how the Receive screen came to show the first wallet's address (and
/// QR code) after a second wallet was imported.
final walletSessionProvider = StateProvider<int>((ref) => 0);

/// Name of the wallet currently open, or null when none is. Kept in step with
/// the persisted last-wallet name so the UI can say which wallet this is.
final openWalletNameProvider = StateProvider<String?>((ref) => null);

/// The open wallet's primary address.
///
/// Watches [walletSessionProvider] so it re-resolves for every wallet.
/// [walletCApiProvider] cannot serve that purpose — it is a singleton that
/// never changes, so watching it alone caches the address for the life of the
/// page.
final primaryAddressProvider = FutureProvider<String>((ref) async {
  ref.watch(walletSessionProvider);
  final ffi = ref.watch(walletCApiProvider);
  if (!ffi.isOpen) throw Exception('Wallet not connected');
  return ffi.getPrimaryAddress();
});
