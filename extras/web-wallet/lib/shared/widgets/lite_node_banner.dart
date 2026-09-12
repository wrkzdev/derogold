import 'package:flutter/material.dart';
import '../../core/api/models/wallet_status.dart';
import '../../l10n/generated/app_localizations.dart';
import '../theme/app_theme.dart';

/// Standing notice for the two things about the connected daemon that a
/// balance on screen cannot show on its own.
///
/// A pruned or lite node answers a scan from its own floor whatever it is
/// asked for, so a wallet older than that node reads a balance that is simply
/// too low with nothing to say why. And when the daemon has refused to serve
/// blocks at all, the heights stop moving with no explanation. This is that
/// "why", and it stays up for as long as it applies — including when the
/// wallet reports itself fully synced, which is exactly when a wrong number
/// looks most trustworthy. Renders nothing against a healthy full node.
///
/// See LITENODE.md.
class LiteNodeBanner extends StatelessWidget {
  final WalletStatus status;

  /// Set on screens that already name the connected node, to drop the leading
  /// label and keep the line short.
  final bool compact;

  const LiteNodeBanner({super.key, required this.status, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (!status.isLiteNode && !status.hasSyncError) {
      return const SizedBox.shrink();
    }

    final tr = S.of(context);
    final node = status.pruneFloor;

    final Color colour;
    final IconData icon;
    final String text;

    if (status.hasSyncError) {
      // The daemon's own words for why it will not serve this wallet. Retrying
      // does not fix what it describes, so it is shown rather than swallowed —
      // and it is shown verbatim, because inventing a friendlier sentence here
      // would mean guessing at a cause the daemon already named.
      colour = kError;
      icon = Icons.error_outline;
      text = status.syncError;
    } else {
      // A node that holds only part of the chain. Nothing is necessarily
      // wrong, but it is worth saying what this node cannot answer for.
      colour = kAccent;
      icon = Icons.info_outline;
      text = tr?.liteNodeServesFrom(node) ??
          'This node only holds blocks from $node onward. Transactions before '
              'that block cannot be found through it.';
    }

    return Container(
      width: double.infinity,
      color: colour.withAlpha(25),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: colour),
          const SizedBox(width: 8),
          if (!compact) ...[
            Text(
              status.hasSyncError
                  ? (tr?.syncStoppedTitle ?? 'Sync stopped')
                  : (tr?.liteNodeTitle ?? 'Lite node'),
              style: TextStyle(
                  color: colour, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: colour, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
