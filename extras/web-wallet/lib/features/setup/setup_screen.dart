import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/wallet_auth.dart';
import '../../core/config/app_config.dart';
import '../../core/ffi/wallet_web.dart';
import '../../core/providers/app_providers.dart';
import '../../core/providers/providers.dart';
import '../../core/providers/wallet_notifiers.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/copy_button.dart';
import '../../shared/widgets/derogold_logo.dart';

enum _SetupMode { menu, create, open, importSeed, importKeys, backupSeed }

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  _SetupMode _mode = _SetupMode.menu;
  bool _loading = false;
  String? _error;

  // Backup confirmation state
  String? _newWalletAddress;
  String? _newWalletSeed;
  String? _newWalletViewKey;
  String? _newWalletSpendKey;
  bool _seedConfirmed = false;

  // SSL for the daemon — refreshed from defaultNodeProvider on entering a form
  bool _daemonSSL = kDefaultDaemonSSL;

  // Wallets already in this browser's IndexedDB, for the Open Wallet selector
  List<String>? _savedWallets; // null = not loaded yet
  String? _selectedWallet;

  // A wallet "file" here is a logical name; the bridge keys IndexedDB by it.
  //
  // _fileCtrl names a NEW wallet (create / import). The Open form deliberately
  // does not share it: it used to, and _loadSavedWallets() overwrote it with
  // the first saved wallet's name. Backing out of Open and going to Import
  // then arrived with someone else's wallet name already in the field, and
  // submitting that overwrote their existing wallet.
  final _fileCtrl = TextEditingController(text: 'my_wallet');
  // Free-typed name for the Open form, used only when nothing is saved yet.
  final _openFileCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();
  final _daemonHostCtrl = TextEditingController(text: kDefaultDaemonHost);
  final _daemonPortCtrl = TextEditingController(text: '$kDefaultDaemonPort');
  final _viewKeyCtrl = TextEditingController();
  final _spendKeyCtrl = TextEditingController();
  final _seedCtrl = TextEditingController();
  final _scanHeightCtrl = TextEditingController(text: '0');

  @override
  void dispose() {
    for (final c in [
      _fileCtrl,
      _openFileCtrl,
      _passCtrl,
      _passConfirmCtrl,
      _daemonHostCtrl,
      _daemonPortCtrl,
      _viewKeyCtrl,
      _spendKeyCtrl,
      _seedCtrl,
      _scanHeightCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The wallet the Open form should open: the dropdown selection when there
  /// are saved wallets, otherwise the free-typed name.
  String get _openWalletName {
    final selected = _selectedWallet?.trim() ?? '';
    if (selected.isNotEmpty) return selected;
    return _openFileCtrl.text.trim();
  }

  int get _scanHeight => int.tryParse(_scanHeightCtrl.text.trim()) ?? 0;

  int get _daemonPort =>
      int.tryParse(_daemonPortCtrl.text.trim()) ?? kDefaultDaemonPort;

  /// Everything that has to happen once a wallet is live: push the settings
  /// the wallet library does not persist itself, record which wallet this is,
  /// and drop every cache belonging to the wallet that was open before.
  Future<void> _afterWalletOpened(WalletCApi ffi, String name) async {
    ffi.setScanCoinbase(ref.read(scanCoinbaseProvider));
    ref.read(txPowServerProvider).applyTo(ffi);
    await storePasswordVerifier(_passCtrl.text);
    await saveLastWalletPath(name);
    if (!mounted) return;
    ref.invalidate(lastWalletPathProvider);
    beginWalletSession(ref, walletName: name);
  }

  /// Shared validation for the forms that name a new wallet.
  String? _validateNewWallet(S? tr) {
    if (_fileCtrl.text.trim().isEmpty) return 'Enter a name for the wallet.';
    if (_passCtrl.text.length < kMinPasswordLength) {
      return tr?.passwordTooShort(kMinPasswordLength) ??
          'Password must be at least $kMinPasswordLength characters';
    }
    return null;
  }

  /// A restore from block zero re-checks most of the chain, which in a browser
  /// is hours of work in a worker the user cannot see. Ask once, with the cost
  /// stated, rather than let it be discovered by watching the bar sit at 3%.
  Future<bool> _confirmSlowScan(int scanHeight) async {
    if (scanHeight >= kSlowRescanHeight) return true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dlgTr = S.of(ctx);
        return AlertDialog(
          title: Text(dlgTr?.scanFromHeight ?? 'Scan from height'),
          content: Text(
            'Scanning from block $scanHeight means fetching and checking every '
            'block from there to the top of the chain, in this browser tab. '
            'That can take a very long time — many hours, or days against a '
            'busy node. If you know roughly when this wallet was first used, '
            'scan from that height instead.',
            style: const TextStyle(height: 1.4),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(dlgTr?.cancel ?? 'Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(dlgTr?.iUnderstandContinue ?? 'I understand, continue'),
            ),
          ],
        );
      },
    );
    if (accepted != true) return false;
    return true;
  }

  Future<void> _doCreate() async {
    final tr = S.of(context);
    if (_passCtrl.text != _passConfirmCtrl.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    final invalid = _validateNewWallet(tr);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    final name = _fileCtrl.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ffi = ref.read(walletCApiProvider);
      await ffi.create(
        name,
        _passCtrl.text,
        _daemonHostCtrl.text.trim(),
        _daemonPort,
        ssl: _daemonSSL,
      );
      final address = await ffi.getPrimaryAddress();
      final seed = await ffi.getMnemonicSeed();
      final keys = await ffi.getSpendKeysJson(address);
      final viewKey = await ffi.getPrivateViewKey();
      await _afterWalletOpened(ffi, name);
      if (!mounted) return;
      setState(() {
        _newWalletAddress = address;
        _newWalletSeed = seed;
        _newWalletSpendKey = keys['privateSpendKey'] as String? ?? '';
        _newWalletViewKey = viewKey;
        _seedConfirmed = false;
        _mode = _SetupMode.backupSeed;
      });
    } on WalletCApiException catch (e) {
      setState(() => _error = e.message.isNotEmpty ? e.message : e.toString());
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _doOpen() async {
    final name = _openWalletName;
    if (name.isEmpty) {
      setState(() => _error = 'Select a wallet to open.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ffi = ref.read(walletCApiProvider);
      await ffi.open(
        name,
        _passCtrl.text,
        _daemonHostCtrl.text.trim(),
        _daemonPort,
        ssl: _daemonSSL,
      );
      await _afterWalletOpened(ffi, name);
      if (!mounted) return;
      ref.read(walletOpenProvider.notifier).state = true;
      context.go('/overview');
    } on WalletCApiException catch (e) {
      setState(() => _error = e.message.isNotEmpty ? e.message : e.toString());
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _doImportSeed() async {
    final tr = S.of(context);
    final invalid = _validateNewWallet(tr);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    if (!await _confirmSlowScan(_scanHeight)) return;
    if (!mounted) return;
    final name = _fileCtrl.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ffi = ref.read(walletCApiProvider);
      await ffi.restoreFromSeed(
        _seedCtrl.text.trim(),
        name,
        _passCtrl.text,
        _daemonHostCtrl.text.trim(),
        _daemonPort,
        scanHeight: _scanHeight,
        ssl: _daemonSSL,
      );
      await _afterWalletOpened(ffi, name);
      if (!mounted) return;
      ref.read(walletOpenProvider.notifier).state = true;
      context.go('/overview');
    } on WalletCApiException catch (e) {
      setState(() => _error = e.message.isNotEmpty ? e.message : e.toString());
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _doImportKeys() async {
    final tr = S.of(context);
    final invalid = _validateNewWallet(tr);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    if (!await _confirmSlowScan(_scanHeight)) return;
    if (!mounted) return;
    final name = _fileCtrl.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ffi = ref.read(walletCApiProvider);
      await ffi.restoreFromKeys(
        _spendKeyCtrl.text.trim(),
        _viewKeyCtrl.text.trim(),
        name,
        _passCtrl.text,
        _daemonHostCtrl.text.trim(),
        _daemonPort,
        scanHeight: _scanHeight,
        ssl: _daemonSSL,
      );
      await _afterWalletOpened(ffi, name);
      if (!mounted) return;
      ref.read(walletOpenProvider.notifier).state = true;
      context.go('/overview');
    } on WalletCApiException catch (e) {
      setState(() => _error = e.message.isNotEmpty ? e.message : e.toString());
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteWallet(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dlgTr = S.of(ctx);
        return AlertDialog(
          title: Text(dlgTr?.deleteWalletData ?? 'Delete wallet?'),
          content: Text(
              'This will permanently delete "$name" from this browser. Make '
              'sure you have your seed phrase backed up.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(dlgTr?.cancel ?? 'Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kError),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(dlgTr?.delete ?? 'Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    // Do not swallow the failure. This used to be a bare `catch (_) {}`, which
    // is how a delete that never reached IndexedDB looked exactly like one
    // that worked — the wallet was simply still in the list afterwards.
    String? failure;
    try {
      await ref.read(walletCApiProvider).deleteFile(name);
    } catch (e) {
      failure = e is WalletCApiException ? e.message : e.toString();
    }
    if (!mounted) return;
    setState(() {
      _savedWallets = null;
      _selectedWallet = null;
      _error = failure == null ? null : 'Could not delete "$name": $failure';
    });
    await _loadSavedWallets();
  }

  Future<void> _loadSavedWallets() async {
    try {
      final wallets = await ref
          .read(walletCApiProvider)
          .listWallets()
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() {
        _savedWallets = wallets;
        // Preselect, but only into the Open form's own state — _fileCtrl names
        // the wallet a create/import is about to write, and pre-filling it
        // with an existing wallet's name is how an import silently replaced
        // the wallet the user had picked here a moment earlier.
        _selectedWallet = wallets.isNotEmpty ? wallets.first : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savedWallets = [];
        _error = e is WalletCApiException ? e.message : e.toString();
      });
    }
  }

  /// Sync the daemon fields from the saved default node preference.
  void _applyNodeDefaults() {
    final node = ref.read(defaultNodeProvider);
    _daemonHostCtrl.text = node.host;
    _daemonPortCtrl.text = '${node.port}';
    setState(() => _daemonSSL = node.ssl);
  }

  void _openPreWalletSettings() {
    showDialog<void>(
      context: context,
      builder: (_) => const _PreWalletSettingsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      body: Stack(
        children: [
          Center(
            child: SizedBox(
              width: narrow
                  ? double.infinity
                  : (_mode == _SetupMode.backupSeed ? 560 : 460),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(narrow ? 20 : 32),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const DeroGoldLogo(size: 48),
                        const SizedBox(height: 28),
                        if (_mode == _SetupMode.menu) _buildMenu(tr),
                        if (_mode == _SetupMode.create) _buildCreate(tr),
                        if (_mode == _SetupMode.open) _buildOpen(tr),
                        if (_mode == _SetupMode.importSeed) _buildImportSeed(tr),
                        if (_mode == _SetupMode.importKeys) _buildImportKeys(tr),
                        if (_mode == _SetupMode.backupSeed) _buildBackupSeed(tr),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          _ErrorBox(message: _error!),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: tr?.settings ?? 'Settings',
              onPressed: _openPreWalletSettings,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenu(S? tr) {
    return Column(
      children: [
        Text(tr?.welcomeToDeroGold ?? 'Welcome to DeroGold Web Wallet',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(tr?.selectOptionToStart ?? 'Select an option to get started',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 28),
        _MenuButton(
          icon: Icons.add_circle_outline,
          label: tr?.createNewWallet ?? 'Create New Wallet',
          onTap: () {
            _applyNodeDefaults();
            setState(() => _mode = _SetupMode.create);
          },
        ),
        const SizedBox(height: 10),
        _MenuButton(
          icon: Icons.folder_open_outlined,
          label: tr?.openExistingWallet ?? 'Open Existing Wallet',
          onTap: () {
            _applyNodeDefaults();
            _loadSavedWallets();
            setState(() => _mode = _SetupMode.open);
          },
        ),
        const SizedBox(height: 10),
        _MenuButton(
          icon: Icons.vpn_key_outlined,
          label: tr?.importFromSeed ?? 'Import from Seed Phrase',
          onTap: () {
            _applyNodeDefaults();
            setState(() => _mode = _SetupMode.importSeed);
          },
        ),
        const SizedBox(height: 10),
        _MenuButton(
          icon: Icons.key_outlined,
          label: tr?.importFromKeys ?? 'Import from Private Keys',
          onTap: () {
            _applyNodeDefaults();
            setState(() => _mode = _SetupMode.importKeys);
          },
        ),
      ],
    );
  }

  Widget _buildCreate(S? tr) {
    return _FormWrapper(
      title: tr?.createNewWallet ?? 'Create New Wallet',
      onBack: () => setState(() {
        _mode = _SetupMode.menu;
        _error = null;
      }),
      loading: _loading,
      onSubmit: _doCreate,
      continueLabel: tr?.continueButton ?? 'Continue',
      children: [
        _TField(ctrl: _fileCtrl, label: tr?.walletFile ?? 'Wallet name'),
        _PassField(ctrl: _passCtrl, label: tr?.walletPassword ?? 'Wallet password'),
        _PassField(ctrl: _passConfirmCtrl, label: 'Confirm password'),
        _DaemonFields(
          hostCtrl: _daemonHostCtrl,
          portCtrl: _daemonPortCtrl,
          hostLabel: tr?.daemonHost ?? 'Daemon host',
          portLabel: tr?.port ?? 'Port',
        ),
      ],
    );
  }

  Widget _buildOpen(S? tr) {
    final wallets = _savedWallets;
    return _FormWrapper(
      title: tr?.openWallet ?? 'Open Wallet',
      onBack: () => setState(() {
        _mode = _SetupMode.menu;
        _error = null;
        _savedWallets = null;
        _selectedWallet = null;
      }),
      loading: _loading,
      onSubmit: _doOpen,
      continueLabel: tr?.continueButton ?? 'Continue',
      children: [
        if (wallets == null)
          // Still reading IndexedDB
          const Center(
              child: SizedBox(
                  height: 48, child: CircularProgressIndicator(strokeWidth: 2)))
        else if (wallets.isEmpty)
          // Nothing saved in this browser — free-type a name
          _TField(ctrl: _openFileCtrl, label: tr?.walletFile ?? 'Wallet name')
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InputDecorator(
                decoration: InputDecoration(
                    labelText: tr?.walletFile ?? 'Wallet name'),
                child: DropdownButton<String>(
                  value: _selectedWallet,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: wallets
                      .map((w) => DropdownMenuItem(value: w, child: Text(w)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedWallet = v),
                ),
              ),
              if (_selectedWallet != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: Text(tr?.deleteWalletData ?? 'Delete wallet'),
                    style: TextButton.styleFrom(
                        foregroundColor: kError, padding: EdgeInsets.zero),
                    onPressed: () => _deleteWallet(_selectedWallet!),
                  ),
                ),
            ],
          ),
        _PassField(ctrl: _passCtrl, label: tr?.walletPassword ?? 'Wallet password'),
        _DaemonFields(
          hostCtrl: _daemonHostCtrl,
          portCtrl: _daemonPortCtrl,
          hostLabel: tr?.daemonHost ?? 'Daemon host',
          portLabel: tr?.port ?? 'Port',
        ),
      ],
    );
  }

  Widget _buildImportSeed(S? tr) {
    return _FormWrapper(
      title: tr?.importFromSeedTitle ?? 'Import from Seed',
      onBack: () => setState(() {
        _mode = _SetupMode.menu;
        _error = null;
      }),
      loading: _loading,
      onSubmit: _doImportSeed,
      continueLabel: tr?.continueButton ?? 'Continue',
      children: [
        _TField(ctrl: _fileCtrl, label: tr?.walletFile ?? 'Wallet name'),
        _PassField(ctrl: _passCtrl, label: tr?.walletPassword ?? 'Wallet password'),
        _TField(
            ctrl: _seedCtrl,
            label: tr?.mnemonicSeedPhrase ?? 'Mnemonic Seed Phrase',
            maxLines: 3),
        _TField(
            ctrl: _scanHeightCtrl,
            label: tr?.scanFromHeight ?? 'Scan from height (0 = full scan)'),
        _DaemonFields(
          hostCtrl: _daemonHostCtrl,
          portCtrl: _daemonPortCtrl,
          hostLabel: tr?.daemonHost ?? 'Daemon host',
          portLabel: tr?.port ?? 'Port',
        ),
      ],
    );
  }

  Widget _buildImportKeys(S? tr) {
    return _FormWrapper(
      title: tr?.importFromKeysTitle ?? 'Import from Keys',
      onBack: () => setState(() {
        _mode = _SetupMode.menu;
        _error = null;
      }),
      loading: _loading,
      onSubmit: _doImportKeys,
      continueLabel: tr?.continueButton ?? 'Continue',
      children: [
        _TField(ctrl: _fileCtrl, label: tr?.walletFile ?? 'Wallet name'),
        _PassField(ctrl: _passCtrl, label: tr?.walletPassword ?? 'Wallet password'),
        _TField(ctrl: _viewKeyCtrl, label: tr?.privateViewKey ?? 'Private View Key'),
        _TField(ctrl: _spendKeyCtrl, label: tr?.privateSpendKey ?? 'Private Spend Key'),
        _TField(
            ctrl: _scanHeightCtrl,
            label: tr?.scanFromHeight ?? 'Scan from height (0 = full scan)'),
        _DaemonFields(
          hostCtrl: _daemonHostCtrl,
          portCtrl: _daemonPortCtrl,
          hostLabel: tr?.daemonHost ?? 'Daemon host',
          portLabel: tr?.port ?? 'Port',
        ),
      ],
    );
  }

  Widget _buildBackupSeed(S? tr) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Warning header
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: kWarning.withAlpha(25),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kWarning.withAlpha(100)),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: kWarning, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr?.backupWarning ??
                      'Back up your wallet before continuing.\n'
                          'These keys cannot be recovered if lost.',
                  style: const TextStyle(
                      color: kWarning, fontSize: 13, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Browser storage is not a safe place to keep the only copy of a
        // wallet: clearing site data, a private window, or a browser cleaning
        // up under storage pressure all take it away without asking.
        Text(
          'This wallet lives in this browser only. Clearing site data removes '
          'it, and only the seed phrase below can bring it back.',
          style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        Text(tr?.yourWalletAddress ?? 'Your Wallet Address',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        _BackupField(value: _newWalletAddress ?? ''),

        const SizedBox(height: 16),
        Text(tr?.seedPhrase25Words ?? 'Seed Phrase (25 words)',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        _BackupField(value: _newWalletSeed ?? '', monospace: true, maxLines: 4),

        const SizedBox(height: 16),
        Text(tr?.privateViewKey ?? 'Private View Key',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        _BackupField(value: _newWalletViewKey ?? '', monospace: true),

        const SizedBox(height: 16),
        Text(tr?.privateSpendKey ?? 'Private Spend Key',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        _BackupField(value: _newWalletSpendKey ?? '', monospace: true),

        const SizedBox(height: 24),
        InkWell(
          onTap: () => setState(() => _seedConfirmed = !_seedConfirmed),
          borderRadius: BorderRadius.circular(6),
          child: Row(
            children: [
              Checkbox(
                value: _seedConfirmed,
                onChanged: (v) => setState(() => _seedConfirmed = v ?? false),
                activeColor: kPrimary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tr?.seedBackupConfirm ??
                      'I have written down my seed phrase and private keys in '
                          'a safe place.',
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _seedConfirmed
                ? () {
                    ref.read(walletOpenProvider.notifier).state = true;
                    context.go('/overview');
                  }
                : null,
            child: Text(tr?.backedUpContinue ??
                'I\'ve backed up my wallet — Continue'),
          ),
        ),
      ],
    );
  }
}

// ── Backup display field ──────────────────────────────────────────────────────

class _BackupField extends StatelessWidget {
  final String value;
  final bool monospace;
  final int maxLines;
  const _BackupField(
      {required this.value, this.monospace = false, this.maxLines = 1});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                fontFamily: monospace ? 'monospace' : null,
                color: Theme.of(context).colorScheme.onSurface,
                height: 1.5,
              ),
              maxLines: maxLines,
            ),
          ),
          const SizedBox(width: 8),
          CopyButton(text: value, size: 16),
        ],
      ),
    );
  }
}

// ── Local helper widgets ──────────────────────────────────────────────────────

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kError.withAlpha(25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kError.withAlpha(80)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: kError, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.isNotEmpty ? message : 'An unknown error occurred.',
              style: const TextStyle(color: kError, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _MenuButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        icon: Icon(icon, size: 18),
        label: Text(label),
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
    );
  }
}

class _FormWrapper extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final bool loading;
  final VoidCallback onSubmit;
  final List<Widget> children;
  final String continueLabel;

  const _FormWrapper({
    required this.title,
    required this.onBack,
    required this.loading,
    required this.onSubmit,
    required this.children,
    this.continueLabel = 'Continue',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          IconButton(
              icon: const Icon(Icons.arrow_back), onPressed: onBack, iconSize: 18),
          const SizedBox(width: 4),
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
          ),
        ]),
        const SizedBox(height: 16),
        ...children.map((w) =>
            Padding(padding: const EdgeInsets.only(bottom: 12), child: w)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: loading ? null : onSubmit,
            child: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : Text(continueLabel),
          ),
        ),
      ],
    );
  }
}

class _PassField extends StatefulWidget {
  final TextEditingController ctrl;
  final String label;
  const _PassField({required this.ctrl, this.label = 'Wallet password'});

  @override
  State<_PassField> createState() => _PassFieldState();
}

class _PassFieldState extends State<_PassField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.ctrl,
      obscureText: _obscure,
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: IconButton(
          icon: Icon(
              _obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 18),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    );
  }
}

class _TField extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final int maxLines;
  const _TField({required this.ctrl, required this.label, this.maxLines = 1});

  @override
  Widget build(BuildContext context) {
    return TextField(
        controller: ctrl,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label));
  }
}

class _DaemonFields extends StatelessWidget {
  final TextEditingController hostCtrl;
  final TextEditingController portCtrl;
  final String hostLabel;
  final String portLabel;
  const _DaemonFields(
      {required this.hostCtrl,
      required this.portCtrl,
      this.hostLabel = 'Daemon host',
      this.portLabel = 'Port'});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
          flex: 3,
          child: TextField(
              controller: hostCtrl,
              decoration: InputDecoration(labelText: hostLabel))),
      const SizedBox(width: 8),
      Expanded(
          child: TextField(
              controller: portCtrl,
              decoration: InputDecoration(labelText: portLabel),
              keyboardType: TextInputType.number)),
    ]);
  }
}

// ── Pre-wallet settings dialog ────────────────────────────────────────────────

class _PreWalletSettingsDialog extends ConsumerStatefulWidget {
  const _PreWalletSettingsDialog();

  @override
  ConsumerState<_PreWalletSettingsDialog> createState() =>
      _PreWalletSettingsDialogState();
}

class _PreWalletSettingsDialogState
    extends ConsumerState<_PreWalletSettingsDialog> {
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  bool _ssl = false;
  bool _saving = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final node = ref.read(defaultNodeProvider);
    _hostCtrl = TextEditingController(text: node.host);
    _portCtrl = TextEditingController(text: '${node.port}');
    _ssl = node.ssl;
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveNode() async {
    setState(() {
      _saving = true;
      _saved = false;
    });
    await ref.read(defaultNodeProvider.notifier).set(
          host: _hostCtrl.text.trim(),
          port: int.tryParse(_portCtrl.text) ?? kDefaultDaemonPort,
          ssl: _ssl,
        );
    if (mounted) {
      setState(() {
        _saving = false;
        _saved = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = S.of(context);
    final themeMode = ref.watch(themeModeProvider);
    final logLevel = ref.watch(logLevelProvider);

    return Dialog(
      child: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title bar
              Row(
                children: [
                  const Icon(Icons.settings_outlined, size: 20),
                  const SizedBox(width: 10),
                  Text(tr?.settings ?? 'Settings',
                      style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(height: 24),

              // Default remote node
              Text(tr?.sectionDaemonNode ?? 'Daemon Node',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                  tr?.nodeDescription ??
                      'Connect to a remote daemon node. Changes take effect '
                          'immediately.',
                  style: const TextStyle(fontSize: 12, color: kTextSecondary)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _hostCtrl,
                      decoration: InputDecoration(
                          labelText: tr?.hostIpAddress ?? 'Host / IP'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _portCtrl,
                      decoration:
                          InputDecoration(labelText: tr?.port ?? 'Port'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    children: [
                      Text(tr?.ssl ?? 'SSL',
                          style: const TextStyle(
                              fontSize: 12, color: kTextSecondary)),
                      Switch(
                          value: _ssl,
                          onChanged: (v) => setState(() {
                                _ssl = v;
                                _saved = false;
                              })),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton(
                    onPressed: _saving ? null : _saveNode,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : Text(tr?.apply ?? 'Apply'),
                  ),
                  if (_saved) ...[
                    const SizedBox(width: 10),
                    const Icon(Icons.check_circle_outline,
                        color: kSuccess, size: 16),
                    const SizedBox(width: 4),
                    Text(tr?.nodeUpdatedSuccess ?? 'Saved',
                        style: const TextStyle(color: kSuccess, fontSize: 13)),
                  ],
                ],
              ),
              const SizedBox(height: 24),

              // Appearance
              Text(tr?.sectionAppearance ?? 'Appearance',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment(
                      value: ThemeMode.system,
                      icon: const Icon(Icons.brightness_auto, size: 16),
                      label: Text(tr?.themeSystem ?? 'System')),
                  ButtonSegment(
                      value: ThemeMode.light,
                      icon: const Icon(Icons.light_mode, size: 16),
                      label: Text(tr?.themeLight ?? 'Light')),
                  ButtonSegment(
                      value: ThemeMode.dark,
                      icon: const Icon(Icons.dark_mode, size: 16),
                      label: Text(tr?.themeDark ?? 'Dark')),
                ],
                selected: {themeMode},
                onSelectionChanged: (s) =>
                    ref.read(themeModeProvider.notifier).set(s.first),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
              const SizedBox(height: 24),

              // Log level
              Text(tr?.sectionDebugLogs ?? 'Debug & Logs',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr?.logLevel ?? 'Log Level',
                            style: TextStyle(
                                fontSize: 14,
                                color: Theme.of(context).colorScheme.onSurface)),
                        Text(
                            tr?.logLevelSubtitle ??
                                'Controls wallet library verbosity',
                            style: const TextStyle(
                                fontSize: 12, color: kTextSecondary)),
                      ],
                    ),
                  ),
                  DropdownButton<WalletLogLevel>(
                    value: logLevel,
                    underline: const SizedBox.shrink(),
                    items: WalletLogLevel.values
                        .map((l) => DropdownMenuItem(
                            value: l,
                            child:
                                Text(l.label, style: const TextStyle(fontSize: 13))))
                        .toList(),
                    onChanged: (l) {
                      if (l != null) ref.read(logLevelProvider.notifier).set(l);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
