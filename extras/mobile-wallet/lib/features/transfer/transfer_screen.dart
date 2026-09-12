import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/api/models/transaction.dart';
import '../../core/ffi/wallet_ffi.dart';
import '../../core/providers/providers.dart';
import '../../core/providers/wallet_notifiers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/amount_formatter.dart';
import '../../shared/utils/haptics.dart';
import '../../shared/widgets/copy_button.dart';

enum _TransferStep { form, review, success }

/// Send screen.
///
/// The wallet backend has no way to construct a transaction without relaying
/// it — `wallet_send_advanced_json` builds and broadcasts in one call — so the
/// review step confirms only what the user asked for. The fee and the ring
/// size are settled when the transaction is built, which is the same moment it
/// is sent, so they appear on the success screen rather than the review one.
class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  _TransferStep _step = _TransferStep.form;
  bool _sweepMode = false;

  // form
  final _addressCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _pidCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  // success
  SendResult? _sent;

  // Transaction proof-of-work progress, polled while a send is in flight.
  Timer? _powTimer;
  String? _powLabel;

  @override
  void dispose() {
    _powTimer?.cancel();
    _addressCtrl.dispose();
    _amountCtrl.dispose();
    _pidCtrl.dispose();
    super.dispose();
  }

  void _startPowPolling() {
    _powLabel = null;
    _powTimer?.cancel();
    _powTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !_loading) {
        _stopPowPolling();
        return;
      }
      final ffi = ref.read(walletCApiProvider);
      final (:active, :elapsedMs, nonces: _) = ffi.getPowStatus();
      if (active) {
        final sec = (elapsedMs / 1000).round();
        final tr = S.of(context);
        setState(() =>
            _powLabel = tr?.computingPow(sec) ?? 'Computing PoW… ${sec}s');
      }
    });
  }

  void _stopPowPolling() {
    _powTimer?.cancel();
    _powTimer = null;
    if (mounted && _powLabel != null) setState(() => _powLabel = null);
  }

  // ── QR scan ──────────────────────────────────────────────────────────────

  Future<void> _scanQr() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _QrScanPage()),
    );
    if (result == null || !mounted) return;

    // Accepts a bare address or a dego:<address>?amount=…&paymentId=… URI.
    final scanned = parseAddressPayload(result);

    // Confirmation dialog
    final use = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dtr = S.of(ctx)!;
        return AlertDialog(
          title: Text(dtr.scannedAddress),
          content: SelectableText(
            scanned.address,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(dtr.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(dtr.useThisAddress),
            ),
          ],
        );
      },
    );
    if (use != true) return;
    setState(() {
      _addressCtrl.text = scanned.address;
      if (scanned.amount != null && parseAmount(scanned.amount!) != null) {
        _amountCtrl.text = scanned.amount!;
      }
      if (scanned.paymentId != null && isValidPaymentId(scanned.paymentId!)) {
        _pidCtrl.text = scanned.paymentId!;
      }
    });
  }

  // ── validate ─────────────────────────────────────────────────────────────

  /// Checks the form and moves to the review step.
  ///
  /// Nothing is built here — a sweep sends straight away, and an ordinary send
  /// waits for the confirmation on the review step.
  Future<void> _review() async {
    final tr = S.of(context)!;
    final address = _addressCtrl.text.trim();
    if (address.isEmpty) {
      setState(() => _error = tr.recipientRequired);
      hapticError();
      return;
    }
    if (!isValidDeroGoldAddress(address)) {
      setState(() => _error = tr.invalidAddress);
      hapticError();
      return;
    }
    if (!isValidPaymentId(_pidCtrl.text.trim())) {
      setState(() => _error = tr.paymentIdInvalid);
      hapticError();
      return;
    }

    if (_sweepMode) {
      await _sweep();
      return;
    }

    final amount = parseAmount(_amountCtrl.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = tr.enterValidAmount);
      hapticError();
      return;
    }

    setState(() {
      _error = null;
      _step = _TransferStep.review;
    });
  }

  // ── send ─────────────────────────────────────────────────────────────────

  /// Builds and broadcasts the transaction in one step.
  ///
  /// This is where the proof of work is computed, so it can occupy the CPU for
  /// seconds — hence the progress label on the button.
  Future<void> _send() async {
    final address = _addressCtrl.text.trim();
    final amount = parseAmount(_amountCtrl.text);
    if (address.isEmpty || amount == null || amount <= 0) return;
    final paymentId = _pidCtrl.text.trim();

    setState(() {
      _loading = true;
      _error = null;
    });
    _startPowPolling();

    try {
      final ffi = ref.read(walletCApiProvider);
      final requestJson = jsonEncode({
        'destinations': [
          {'address': address, 'amount': amount}
        ],
        if (paymentId.isNotEmpty) 'paymentID': paymentId,
      });
      final result = await ffi.sendAdvanced(requestJson);
      ref.read(balanceProvider.notifier).refresh();
      ref.read(transactionsProvider.notifier).refresh();
      hapticHeavy();
      if (!mounted) return;
      setState(() {
        _sent = SendResult.fromJson(result);
        _step = _TransferStep.success;
      });
    } on WalletCApiException catch (e) {
      hapticError();
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      hapticError();
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      _stopPowPolling();
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Sweeps everything spendable to the address in the form.
  ///
  /// A sweep splits itself over as many transactions as it takes, each with
  /// its own proof of work, and it sends immediately — there is no review step
  /// for it, because there is nothing to review that the form does not already
  /// show.
  Future<void> _sweep() async {
    final tr = S.of(context)!;
    final address = _addressCtrl.text.trim();

    setState(() {
      _loading = true;
      _error = null;
    });
    _startPowPolling();

    try {
      final ffi = ref.read(walletCApiProvider);
      final result = await ffi.sweepToAddress(
        address,
        paymentId: _pidCtrl.text.trim(),
      );
      final results = result['results'] as List<dynamic>? ?? const [];
      final successes = results
          .whereType<Map>()
          .where((r) => r.containsKey('txHash'))
          .toList();
      if (successes.isEmpty) {
        // `results` can be empty as well as all-errors; don't index blindly.
        final first = results.whereType<Map>().firstOrNull;
        throw WalletCApiException(
          (first?['error'] as num?)?.toInt() ?? -1,
          first?['errorMessage'] as String? ?? tr.sweepFailed,
        );
      }
      final hashes = successes.map((r) => r['txHash'] as String).join(', ');
      ref.read(balanceProvider.notifier).refresh();
      ref.read(transactionsProvider.notifier).refresh();
      hapticHeavy();
      if (!mounted) return;
      setState(() {
        _sent = SendResult(
            transactionHash: hashes, fee: 0, relayedToNetwork: true);
        _step = _TransferStep.success;
      });
    } on WalletCApiException catch (e) {
      hapticError();
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      hapticError();
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      _stopPowPolling();
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Back from review to the form. Nothing was built, so there is nothing to
  /// undo beyond the step itself.
  void _backToForm() {
    setState(() {
      _step = _TransferStep.form;
      _error = null;
    });
  }

  void _reset() {
    setState(() {
      _step = _TransferStep.form;
      _addressCtrl.clear();
      _amountCtrl.clear();
      _pidCtrl.clear();
      _sent = null;
      _error = null;
      _sweepMode = false;
    });
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _TransferStep.form:
        return _buildForm();
      case _TransferStep.review:
        return _buildReview();
      case _TransferStep.success:
        return _buildSuccess();
    }
  }

  Widget _busyChild(String label) {
    if (!_loading) return Text(label);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
        if (_powLabel != null) ...[
          const SizedBox(width: 10),
          Text(_powLabel!, style: const TextStyle(fontSize: 13)),
        ],
      ],
    );
  }

  Widget _errorBox() {
    if (_error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kError.withAlpha(25),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(_error!,
            style: const TextStyle(color: kError, fontSize: 13)),
      ),
    );
  }

  // ── form ─────────────────────────────────────────────────────────────────

  Widget _buildForm() {
    final tr = S.of(context)!;
    final balanceAsync = ref.watch(balanceProvider);
    final available = balanceAsync.valueOrNull?.unlocked ?? 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Sweep toggle
        Row(
          children: [
            Text(
              _sweepMode ? tr.sweepAllFunds : tr.send,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Spacer(),
            TextButton(
              onPressed: _loading
                  ? null
                  : () => setState(() {
                        _sweepMode = !_sweepMode;
                        _error = null;
                      }),
              child: Text(_sweepMode ? tr.normalSend : tr.sweep),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Address
        TextField(
          controller: _addressCtrl,
          decoration: InputDecoration(
            labelText: tr.recipientAddress,
            hintText: 'dg...',
            suffixIcon: IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: _scanQr,
              tooltip: tr.scanQr,
            ),
          ),
          maxLines: 2,
          minLines: 1,
        ),
        const SizedBox(height: 16),

        // Amount (only for normal send)
        if (!_sweepMode) ...[
          TextField(
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: tr.amount,
              hintText: '0.00',
              helperText: tr.availableBalance(
                  formatAmount(available, showTicker: true)),
            ),
          ),
          const SizedBox(height: 16),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kPrimary.withAlpha(15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: kPrimary, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr.sweepInfo(
                        formatAmount(available, showTicker: true)),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Payment ID
        TextField(
          controller: _pidCtrl,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: tr.paymentIdOptional,
            hintText: tr.hexCharacters,
            errorText: isValidPaymentId(_pidCtrl.text.trim())
                ? null
                : tr.mustBeHex,
          ),
        ),
        const SizedBox(height: 8),

        _errorBox(),

        const SizedBox(height: 24),

        FilledButton(
          onPressed: _loading ? null : _review,
          child: _busyChild(
              _sweepMode ? tr.sweepAllFunds : tr.reviewTransaction),
        ),
      ],
    );
  }

  // ── review ───────────────────────────────────────────────────────────────

  Widget _buildReview() {
    final tr = S.of(context)!;
    final amount = parseAmount(_amountCtrl.text) ?? 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(tr.reviewTransaction,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),

        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _reviewRow(tr.to, _addressCtrl.text.trim()),
                const Divider(height: 24),
                _reviewRow(tr.amount,
                    formatAmount(amount, showTicker: true)),
                // No fee here on purpose: it is settled when the transaction
                // is built, which is the same moment it is sent, so any figure
                // shown now would be a guess. The exact fee is on the next
                // screen.
                _reviewRow(tr.fee, tr.feeDeductedOnSend),
                if (_pidCtrl.text.trim().isNotEmpty) ...[
                  const Divider(height: 24),
                  _reviewRow(tr.paymentId, _pidCtrl.text.trim()),
                ],
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kWarning.withAlpha(25),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber, color: kWarning, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr.transactionsIrreversible,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: kWarning),
                ),
              ),
            ],
          ),
        ),

        _errorBox(),

        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _loading ? null : _backToForm,
                child: Text(tr.back),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: _loading ? null : _send,
                child: _busyChild(tr.confirmAndSend),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _reviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(value,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  // ── success ──────────────────────────────────────────────────────────────

  Widget _buildSuccess() {
    final tr = S.of(context)!;
    final sent = _sent!;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: kSuccess.withAlpha(25),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check, color: kSuccess, size: 40),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(tr.transactionSent,
              style: Theme.of(context).textTheme.headlineMedium),
        ),
        const SizedBox(height: 20),

        // The fee and the ring size are only knowable once the transaction has
        // been built, which is the same call that sent it — so they are
        // reported here rather than on the review step.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                if (sent.fee > 0)
                  _reviewRow(tr.fee,
                      formatAmount(sent.fee, showTicker: true)),
                // Zero means the native library predates reporting it, and a
                // made-up ring size would be worse than none.
                if (sent.defaultMixin > 0)
                  _reviewRow(tr.ringSize, '${sent.mixin + 1}'),
                _reviewRow(tr.transactionHash, sent.transactionHash),
              ],
            ),
          ),
        ),

        // The transaction is already on its way, so this is no longer a
        // warning to act on — but it still explains why this one is less
        // private than usual.
        if (sent.isMixinDegraded) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kWarning.withAlpha(25),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.privacy_tip_outlined,
                    color: kWarning, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr.ringSizeReduced(
                        sent.mixin + 1, sent.defaultMixin + 1),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: kWarning),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CopyButton(text: sent.transactionHash),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.share,
                  size: 20,
                  color: Theme.of(context).textTheme.bodySmall?.color),
              tooltip: tr.share,
              onPressed: () {
                hapticLight();
                Share.share(sent.transactionHash);
              },
            ),
          ],
        ),
        const SizedBox(height: 32),
        OutlinedButton(
          onPressed: _reset,
          child: Text(tr.sendAnother),
        ),
      ],
    );
  }
}

// ── QR scanner page ──────────────────────────────────────────────────────────

class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final _controller = MobileScannerController();
  bool _scanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(tr.scanQrCode)),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_scanned || !mounted) return;
          final barcode = capture.barcodes.firstOrNull;
          if (barcode?.rawValue == null) return;
          _scanned = true;
          hapticMedium();
          Navigator.of(context).pop(barcode!.rawValue);
        },
      ),
    );
  }
}
