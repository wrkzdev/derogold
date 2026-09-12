/// The wallet's view of itself and of the daemon it is talking to, as
/// `wallet_get_status_json` reports it. Every field here has a counterpart in
/// that JSON; nothing is inferred.
class WalletStatus {
  final int walletBlockCount;
  final int localDaemonBlockCount;
  final int networkBlockCount;
  final bool isDaemonSynced;
  final bool isWalletSynced;
  final bool isOutOfSync;
  final int peerCount;
  final int hashrate;
  final bool isViewWallet;
  final int subWalletCount;

  /// The ring sizes the network expects at the current height. Zero against a
  /// wallet_capi too old to report them, which every reader must treat as
  /// "unknown" rather than as a real limit.
  final int minMixin;
  final int maxMixin;
  final int defaultMixin;

  /// The lowest height the connected daemon can serve a block body from. Zero
  /// means it holds the whole chain. Non-zero means it is pruned or running in
  /// lite mode: nothing below this height can be found through it however far
  /// back a scan is started, so a wallet older than this shows an incomplete
  /// balance. See LITENODE.md.
  final int pruneFloor;

  /// Empty unless the daemon has said why it will not serve this wallet
  /// blocks. Retrying does not fix what it describes, so it belongs on screen
  /// rather than in a log.
  final String syncError;

  /// Chain reorganisations resolved since the wallet was opened, and where the
  /// most recent one was. The count only ever rises, so a screen polling it can
  /// tell one happened between two polls — which matters, because a reorg
  /// silently withdraws transactions it had already reported as confirmed.
  final int forkCount;
  final int lastForkHeight;
  final int lastForkDepth;

  /// This wallet synced without scanning coinbase transactions and is now set
  /// to scan them. The blocks holding nothing but a coinbase were never sent to
  /// it, so only a rescan can recover them.
  final bool coinbaseScanNeedsReset;

  const WalletStatus({
    required this.walletBlockCount,
    required this.localDaemonBlockCount,
    required this.networkBlockCount,
    required this.isDaemonSynced,
    required this.isWalletSynced,
    required this.isOutOfSync,
    required this.peerCount,
    required this.hashrate,
    required this.isViewWallet,
    required this.subWalletCount,
    this.minMixin = 0,
    this.maxMixin = 0,
    this.defaultMixin = 0,
    this.pruneFloor = 0,
    this.syncError = '',
    this.forkCount = 0,
    this.lastForkHeight = 0,
    this.lastForkDepth = 0,
    this.coinbaseScanNeedsReset = false,
  });

  factory WalletStatus.fromJson(Map<String, dynamic> json) => WalletStatus(
        walletBlockCount: (json['walletBlockCount'] as num).toInt(),
        localDaemonBlockCount: (json['localDaemonBlockCount'] as num).toInt(),
        networkBlockCount: (json['networkBlockCount'] as num).toInt(),
        isDaemonSynced: json['isDaemonSynced'] as bool,
        isWalletSynced: json['isWalletSynced'] as bool,
        isOutOfSync: json['isOutOfSync'] as bool,
        peerCount: (json['peerCount'] as num).toInt(),
        hashrate: (json['hashrate'] as num).toInt(),
        isViewWallet: json['isViewWallet'] as bool,
        subWalletCount: (json['subWalletCount'] as num).toInt(),
        minMixin: (json['minMixin'] as num?)?.toInt() ?? 0,
        maxMixin: (json['maxMixin'] as num?)?.toInt() ?? 0,
        defaultMixin: (json['defaultMixin'] as num?)?.toInt() ?? 0,
        pruneFloor: (json['pruneFloor'] as num?)?.toInt() ?? 0,
        syncError: json['syncError'] as String? ?? '',
        forkCount: (json['forkCount'] as num?)?.toInt() ?? 0,
        lastForkHeight: (json['lastForkHeight'] as num?)?.toInt() ?? 0,
        lastForkDepth: (json['lastForkDepth'] as num?)?.toInt() ?? 0,
        coinbaseScanNeedsReset:
            json['coinbaseScanNeedsReset'] as bool? ?? false,
      );

  /// Sync progress 0.0 → 1.0
  double get syncProgress {
    if (networkBlockCount == 0) return 0.0;
    return (walletBlockCount / networkBlockCount).clamp(0.0, 1.0);
  }

  /// The connected daemon holds no block data below [pruneFloor], so it is
  /// either pruned or a lite node.
  bool get isLiteNode => pruneFloor > 0;

  /// The daemon has given a reason it cannot serve this wallet.
  bool get hasSyncError => syncError.isNotEmpty;
}
