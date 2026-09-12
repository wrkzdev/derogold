import 'package:flutter_test/flutter_test.dart';
import 'package:derogold_wallet/core/api/models/transaction.dart';
import 'package:derogold_wallet/core/api/models/wallet_status.dart';
import 'package:derogold_wallet/shared/utils/amount_formatter.dart';

void main() {
  group('Amount formatting', () {
    test('formats zero', () {
      expect(formatAmount(0), '0.00');
    });

    test('formats whole amounts', () {
      expect(formatAmount(100), '1.00');
      expect(formatAmount(100000), '1,000.00');
    });

    test('formats fractional amounts', () {
      expect(formatAmount(150), '1.50');
      expect(formatAmount(1), '0.01');
      expect(formatAmount(99), '0.99');
    });

    test('formats with ticker', () {
      expect(formatAmount(100, showTicker: true), '1.00 DEGO');
    });

    test('formats negative amounts', () {
      expect(formatAmount(-250), '-2.50');
    });

    test('keeps the sign on sub-unit negatives', () {
      // `atomic ~/ divisor` truncates toward zero, so the whole part is 0 here
      // and the minus sign has to be carried explicitly.
      expect(formatAmount(-50), '-0.50');
      expect(formatAmount(-1), '-0.01');
      expect(formatAmount(-99), '-0.99');
    });
  });

  group('Amount parsing', () {
    test('parses simple amounts', () {
      expect(parseAmount('1.00'), 100);
      expect(parseAmount('0.50'), 50);
      expect(parseAmount('1000'), 100000);
    });

    test('parses with commas', () {
      expect(parseAmount('1,000.00'), 100000);
    });

    test('returns null for invalid input', () {
      expect(parseAmount(''), null);
      expect(parseAmount('abc'), null);
      expect(parseAmount('1.234'), null);
    });

    test('rejects negative amounts', () {
      expect(parseAmount('-5'), null);
      expect(parseAmount('-0.01'), null);
    });
  });

  group('Address validation', () {
    // 97 characters, base58, "dg" prefix.
    final validAddress = 'dg${'a' * 95}';

    test('accepts a well-formed address', () {
      expect(validAddress.length, 97);
      expect(isValidDeroGoldAddress(validAddress), isTrue);
    });

    test('accepts an integrated address', () {
      expect(isValidDeroGoldAddress('dg${'a' * 183}'), isTrue);
    });

    test('rejects a wrong prefix', () {
      expect(isValidDeroGoldAddress('xg${'a' * 95}'), isFalse);
    });

    test('rejects a wrong length', () {
      expect(isValidDeroGoldAddress('dg${'a' * 94}'), isFalse);
    });

    test('rejects non-base58 characters', () {
      // 0, O, I and l are not in the CryptoNote base58 alphabet.
      expect(isValidDeroGoldAddress('dg${'a' * 94}0'), isFalse);
    });
  });

  group('Payment ID validation', () {
    test('accepts empty (means none)', () {
      expect(isValidPaymentId(''), isTrue);
    });

    test('accepts 16 and 64 hex characters', () {
      expect(isValidPaymentId('0' * 16), isTrue);
      expect(isValidPaymentId('aF' * 32), isTrue);
    });

    test('rejects other lengths and non-hex', () {
      expect(isValidPaymentId('0' * 15), isFalse);
      expect(isValidPaymentId('g' * 16), isFalse);
    });
  });

  group('QR payload parsing', () {
    test('passes a bare address through', () {
      final r = parseAddressPayload('dgabc');
      expect(r.address, 'dgabc');
      expect(r.amount, isNull);
      expect(r.paymentId, isNull);
    });

    test('parses a dego: URI with parameters', () {
      final r = parseAddressPayload('dego:dgabc?amount=1.50&paymentId=abcd');
      expect(r.address, 'dgabc');
      expect(r.amount, '1.50');
      expect(r.paymentId, 'abcd');
    });

    test('parses a dego: URI without parameters', () {
      final r = parseAddressPayload('dego:dgabc');
      expect(r.address, 'dgabc');
      expect(r.amount, isNull);
    });

    test('trims surrounding whitespace', () {
      expect(parseAddressPayload('  dgabc  ').address, 'dgabc');
    });
  });

  group('Transaction direction', () {
    Transaction tx(int totalAmount, List<int> transferAmounts) =>
        Transaction.fromJson({
          'hash': 'h',
          'timestamp': 0,
          'blockHeight': 1,
          'totalAmount': totalAmount,
          'transfers': [
            for (final a in transferAmounts) {'amount': a, 'type': a >= 0 ? 1 : 0},
          ],
        });

    test('a plain receive is incoming', () {
      expect(tx(500, [500]).isIncoming, isTrue);
    });

    test('a plain send is outgoing', () {
      expect(tx(-500, [-500]).isIncoming, isFalse);
    });

    test('a send with change to another subwallet is still outgoing', () {
      // The positive transfer is this wallet's own change. Judging direction
      // from the individual transfers would call this incoming.
      expect(tx(-500, [-1500, 1000]).isIncoming, isFalse);
    });

    test('tolerates a missing transfers list', () {
      final t = Transaction.fromJson({'hash': 'h', 'totalAmount': 10});
      expect(t.transfers, isEmpty);
      expect(t.isIncoming, isTrue);
    });
  });

  // A pruned or lite node answers every scan from its own floor, so how the
  // app reads these fields decides whether a wallet older than the node shows
  // a balance that is quietly wrong. See LITENODE.md.
  group('Node and sync status', () {
    WalletStatus status({int pruneFloor = 0, String syncError = ''}) =>
        WalletStatus.fromJson({
          'walletBlockCount': 4200000,
          'localDaemonBlockCount': 4200000,
          'networkBlockCount': 4200000,
          'isDaemonSynced': true,
          'isWalletSynced': true,
          'isOutOfSync': false,
          'peerCount': 8,
          'hashrate': 0,
          'isViewWallet': false,
          'subWalletCount': 1,
          'pruneFloor': pruneFloor,
          'syncError': syncError,
        });

    test('a daemon holding the whole chain is not a lite node', () {
      final s = status();
      expect(s.isLiteNode, isFalse);
      expect(s.hasSyncError, isFalse);
    });

    test('a non-zero prune floor is a lite or pruned node', () {
      final s = status(pruneFloor: 4100000);
      expect(s.isLiteNode, isTrue);
      expect(s.pruneFloor, 4100000);
    });

    test('a daemon refusal is reported verbatim', () {
      final s = status(syncError: 'daemon is pruned below the requested range');
      expect(s.hasSyncError, isTrue);
      expect(s.syncError, 'daemon is pruned below the requested range');
    });

    test('fields absent from an older wallet_capi read as a healthy full node',
        () {
      final s = WalletStatus.fromJson({
        'walletBlockCount': 1,
        'localDaemonBlockCount': 1,
        'networkBlockCount': 1,
        'isDaemonSynced': true,
        'isWalletSynced': true,
        'isOutOfSync': false,
        'peerCount': 0,
        'hashrate': 0,
        'isViewWallet': false,
        'subWalletCount': 1,
      });
      expect(s.isLiteNode, isFalse);
      expect(s.hasSyncError, isFalse);
      expect(s.coinbaseScanNeedsReset, isFalse);
      expect(s.forkCount, 0);
    });

    test('ring sizes default to unknown rather than to a real limit', () {
      final s = status();
      expect(s.minMixin, 0);
      expect(s.maxMixin, 0);
      expect(s.defaultMixin, 0);
    });
  });

  // The fee and the ring size only exist once the transaction has been built,
  // which for this backend is the same call that sends it.
  group('Send result', () {
    test('reports the fee and ring size the backend settled on', () {
      final r = SendResult.fromJson({
        'transactionHash': 'abc',
        'fee': 1000,
        'mixin': 3,
        'defaultMixin': 3,
      });
      expect(r.fee, 1000);
      expect(r.mixin, 3);
      expect(r.isMixinDegraded, isFalse);
    });

    test('flags a ring smaller than the network default', () {
      final r = SendResult.fromJson(
          {'transactionHash': 'abc', 'mixin': 1, 'defaultMixin': 3});
      expect(r.isMixinDegraded, isTrue);
    });

    test('an older wallet_capi reporting neither is not degraded', () {
      final r = SendResult.fromJson({'transactionHash': 'abc'});
      expect(r.isMixinDegraded, isFalse);
    });
  });
}
