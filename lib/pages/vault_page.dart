import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/vault_entry.dart';
import '../services/native_storage.dart';
import '../services/transfer/transfer_service.dart';
import '../services/vault_service.dart';
import '../theme/app_sizes.dart';
import '../widgets/document_picker.dart';
import 'receive_secret_page.dart';
import 'send_secret_page.dart';

/// Screens the vault can be filtered to.
enum _VaultFilter { all, mine, received }

/// Screen presenting the encrypted files tracked by the vault index.
class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final Set<String> _selectedIds = <String>{};
  String? _busyMessage;
  _VaultFilter _filter = _VaultFilter.all;

  VaultService get _vault => VaultService.instance;
  TransferService get _transfer => TransferService.instance;

  bool get _selecting => _selectedIds.isNotEmpty;
  bool get _busy => _busyMessage != null || _vault.isBusy;

  List<VaultEntry> get _filteredEntries {
    switch (_filter) {
      case _VaultFilter.all:
        return _vault.entries;
      case _VaultFilter.mine:
        return _vault.entries
            .where((entry) => !entry.isReceived)
            .toList(growable: false);
      case _VaultFilter.received:
        return _vault.entries
            .where((entry) => entry.isReceived)
            .toList(growable: false);
    }
  }

  List<VaultEntry> get _selectedEntries => _vault.entries
      .where((entry) => _selectedIds.contains(entry.id))
      .toList(growable: false);

  void _toggleSelection(VaultEntry entry) {
    setState(() {
      if (_selectedIds.contains(entry.id)) {
        _selectedIds.remove(entry.id);
      } else {
        _selectedIds.add(entry.id);
      }
    });
  }

  void _clearSelection() {
    setState(() => _selectedIds.clear());
  }

  void _toggleSelectAll() {
    final all = _filteredEntries;
    setState(() {
      if (_selectedIds.length == all.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(all.map((entry) => entry.id));
      }
    });
  }

  Future<void> _startSend() async {
    if (_transfer.hasActive) {
      await _resumeTransfer();
      return;
    }
    if (_vault.entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lock a file before sending one')),
      );
      return;
    }

    final entry = await showModalBottomSheet<VaultEntry>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final primaryColor = Theme.of(ctx).primaryColor;
        final secondaryColor = isDark ? Colors.white54 : Colors.black54;
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                  child: Row(
                    children: [
                      Icon(Icons.send_outlined, color: primaryColor),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Choose a locked file',
                          style: TextStyle(
                            fontSize: AppSizes.subtitle + 1,
                            color: primaryColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: _vault.entries.length,
                    itemBuilder: (context, index) {
                      final candidate = _vault.entries[index];
                      return ListTile(
                        leading: Icon(
                          _iconFor(candidate.mime),
                          size: AppSizes.icon - 2,
                          color: primaryColor,
                        ),
                        title: Text(
                          candidate.name,
                          style: TextStyle(
                            fontSize: AppSizes.subtitle + 1,
                            color: primaryColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${candidate.isReceived ? 'Received' : 'Locked'} · ${_formatBytes(candidate.size)}',
                          style: TextStyle(
                            color: secondaryColor,
                            fontSize: 13,
                          ),
                        ),
                        onTap: () => Navigator.of(ctx).pop(candidate),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (entry == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SendSecretPage(entry: entry)),
    );
  }

  Future<void> _startReceive() async {
    if (_transfer.hasActive) {
      await _resumeTransfer();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ReceiveSecretPage()),
    );
  }

  Future<void> _resumeTransfer() async {
    final sender = _transfer.sender;
    final receiver = _transfer.receiver;
    if (sender != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SendSecretPage(entry: sender.entry, sender: sender),
        ),
      );
    } else if (receiver != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReceiveSecretPage(receiver: receiver),
        ),
      );
    }
  }

  Future<void> _showActions(VaultEntry entry) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;
    final isImage = entry.mime.startsWith('image/');

    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                  child: Row(
                    children: [
                      Icon(
                        _iconFor(entry.mime),
                        size: AppSizes.icon - 2,
                        color: primaryColor,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          entry.name,
                          style: TextStyle(
                            fontSize: AppSizes.subtitle + 1,
                            color: primaryColor,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (isImage)
                  ListTile(
                    leading: Icon(
                      Icons.visibility_outlined,
                      color: primaryColor,
                    ),
                    title: Text(
                      'Preview',
                      style: TextStyle(color: primaryColor),
                    ),
                    onTap: () => Navigator.of(ctx).pop('preview'),
                  ),
                ListTile(
                  leading: Icon(Icons.open_in_new, color: primaryColor),
                  title: Text(
                    'Open With',
                    style: TextStyle(color: primaryColor),
                  ),
                  onTap: () => Navigator.of(ctx).pop('open'),
                ),
                ListTile(
                  leading: Icon(Icons.save_alt, color: primaryColor),
                  title: Text(
                    'Save a Copy',
                    style: TextStyle(color: primaryColor),
                  ),
                  onTap: () => Navigator.of(ctx).pop('save'),
                ),
                if (!entry.isReceived)
                  ListTile(
                    leading: Icon(Icons.restore, color: primaryColor),
                    title: Text(
                      'Restore',
                      style: TextStyle(color: primaryColor),
                    ),
                    subtitle: Text(
                      'Decrypt and put the original file back',
                      style: TextStyle(color: secondaryColor, fontSize: 12),
                    ),
                    onTap: () => Navigator.of(ctx).pop('restore'),
                  ),
                ListTile(
                  leading: Icon(Icons.share_outlined, color: primaryColor),
                  title: Text('Share', style: TextStyle(color: primaryColor)),
                  onTap: () => Navigator.of(ctx).pop('share'),
                ),
                ListTile(
                  leading: Icon(Icons.send_outlined, color: primaryColor),
                  title: Text(
                    'Send Secret File',
                    style: TextStyle(color: primaryColor),
                  ),
                  subtitle: Text(
                    'Send this file directly to a CurveVault identity',
                    style: TextStyle(color: secondaryColor, fontSize: 12),
                  ),
                  onTap: () => Navigator.of(ctx).pop('send_secret'),
                ),
                ListTile(
                  leading: Icon(Icons.vpn_key_outlined, color: primaryColor),
                  title: Text(
                    'Share with Identity',
                    style: TextStyle(color: primaryColor),
                  ),
                  subtitle: Text(
                    'Encrypt a copy for a Curve256189 public key',
                    style: TextStyle(color: secondaryColor, fontSize: 12),
                  ),
                  onTap: () => Navigator.of(ctx).pop('share_identity'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: const Text(
                    'Delete Permanently',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                  subtitle: Text(
                    'The encrypted file will be removed from disk.',
                    style: TextStyle(color: secondaryColor, fontSize: 12),
                  ),
                  onTap: () => Navigator.of(ctx).pop('delete'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) return;

    switch (action) {
      case 'preview':
        await _preview(entry);
      case 'open':
        await _runAction(
          'Decrypting ${entry.name}...',
          () => _vault.open(entry),
        );
      case 'save':
        await _runAction(
          'Preparing ${entry.name}...',
          () => _vault.saveAs(entry),
        );
      case 'restore':
        await _restoreEntry(entry);
      case 'share':
        await _runAction(
          'Preparing ${entry.name}...',
          () => _vault.share(entry),
        );
      case 'share_identity':
        await _shareWithIdentity(entry);
      case 'send_secret':
        if (!mounted) return;
        if (_transfer.hasActive) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Finish the current transfer first'),
            ),
          );
          await _resumeTransfer();
          return;
        }
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SendSecretPage(entry: entry)),
        );
      case 'delete':
        await _deleteEntries([entry]);
    }
  }

  Future<void> _preview(VaultEntry entry) async {
    File? file;
    try {
      setState(() => _busyMessage = 'Decrypting ${entry.name}...');
      file = await _vault.decryptToTemp(entry);
      if (!mounted) return;
      setState(() => _busyMessage = null);
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Theme.of(ctx).scaffoldBackgroundColor,
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      hoverColor: Colors.transparent,
                      focusColor: Colors.transparent,
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(maxScale: 5, child: Image.file(file!)),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted && _busyMessage != null) {
        setState(() => _busyMessage = null);
      }
      try {
        if (file != null && file.existsSync()) {
          file.deleteSync();
        }
      } catch (_) {
        // The next unlock cleans the cache directory.
      }
    }
  }

  Future<void> _shareWithIdentity(VaultEntry entry) async {
    final controller = TextEditingController();
    String? errorText;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;

    final hex = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            title: const Text('Share with Identity'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Paste the recipient\'s 64-character Curve256189 public key. '
                    'They can open the shared .cvlt file with their own identity.',
                    style: TextStyle(
                      color: secondaryColor,
                      fontSize: AppSizes.subtitle,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    maxLines: 2,
                    style: TextStyle(
                      color: primaryColor,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Recipient Public Key',
                      labelStyle: TextStyle(
                        color: secondaryColor,
                        fontSize: 13,
                      ),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(
                          color: isDark ? Colors.white24 : Colors.black26,
                        ),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: primaryColor),
                      ),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorText!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('Cancel', style: TextStyle(color: secondaryColor)),
              ),
              TextButton(
                onPressed: () {
                  final normalized = controller.text
                      .replaceAll(RegExp(r'\s'), '')
                      .toLowerCase();
                  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
                    setDialogState(
                      () => errorText = 'Enter a 64-character hex public key',
                    );
                    return;
                  }
                  Navigator.of(ctx).pop(normalized);
                },
                child: Text('Share', style: TextStyle(color: primaryColor)),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (hex == null || !mounted) return;

    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }

    await _runAction(
      'Encrypting shared copy...',
      () => _vault.shareWithIdentity(entry, bytes),
    );
  }

  Future<void> _runAction(
    String message,
    Future<void> Function() action,
  ) async {
    if (_busy) return;
    setState(() => _busyMessage = message);
    try {
      await action();
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busyMessage = null);
    }
  }

  Future<void> _restoreEntry(VaultEntry entry) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).scaffoldBackgroundColor,
        title: const Text('Restore Original File?'),
        content: Text(
          'The encrypted .cvlt file will be decrypted and put back as '
          '"${entry.name}" in its original folder. The encrypted container '
          'is then removed from the vault, so the file becomes readable by '
          'anyone with access to that folder.',
          style: const TextStyle(fontSize: AppSizes.subtitle, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyMessage = 'Restoring ${entry.name}...');
    try {
      await _vault.restore(entry);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Restored ${entry.name}')));
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busyMessage = null);
    }
  }

  Future<void> _restoreEntries(List<VaultEntry> entries) async {
    if (entries.isEmpty || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).scaffoldBackgroundColor,
        title: Text(
          entries.length == 1
              ? 'Restore Original File?'
              : 'Restore ${entries.length} Files?',
        ),
        content: const Text(
          'The selected files will be decrypted and put back under their '
          'original names in their original folders. The encrypted '
          'containers are then removed from the vault, so the files become '
          'readable by anyone with access to those folders.',
          style: TextStyle(fontSize: AppSizes.subtitle, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final summary = await _vault.restoreEntries(entries);
      if (!mounted) return;
      setState(() => _selectedIds.clear());
      final parts = <String>[];
      if (summary.locked > 0) {
        parts.add(
          'Restored ${summary.locked} file${summary.locked == 1 ? '' : 's'}',
        );
      }
      if (summary.failures.isNotEmpty) {
        parts.add('${summary.failures.length} failed');
      }
      if (parts.isEmpty) {
        parts.add('Nothing was restored');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(parts.join(' · ')),
          action: summary.failures.isEmpty
              ? null
              : SnackBarAction(
                  label: 'Details',
                  onPressed: () => _showFailures(
                    summary.failures,
                    title: 'Could not restore every file',
                  ),
                ),
        ),
      );
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _deleteEntries(List<VaultEntry> entries) async {
    if (entries.isEmpty || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).scaffoldBackgroundColor,
        title: Text(
          entries.length == 1
              ? 'Delete Encrypted File?'
              : 'Delete ${entries.length} Encrypted Files?',
        ),
        content: Text(
          'This permanently deletes the .cvlt container'
          '${entries.length == 1 ? '' : 's'} from disk. '
          'The original content cannot be recovered unless you have a copy.',
          style: const TextStyle(fontSize: AppSizes.subtitle, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyMessage = 'Deleting...');
    try {
      final failures = await _vault.deleteEntries(entries);
      if (!mounted) return;
      setState(() => _selectedIds.clear());
      if (failures.isNotEmpty) {
        _showFailures(failures);
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busyMessage = null);
    }
  }

  Future<void> _recoverFolder() async {
    if (_busy) return;
    try {
      final folder = await NativeStorage.pickFolder();
      if (!mounted || folder == null) return;
      final summary = await _vault.recoverFolder(folder);
      if (!mounted) return;
      final parts = <String>[];
      if (summary.locked > 0) {
        parts.add(
          'Recovered ${summary.locked} file${summary.locked == 1 ? '' : 's'}',
        );
      }
      if (summary.failures.isNotEmpty) {
        parts.add('${summary.failures.length} could not be read');
      }
      if (parts.isEmpty) {
        parts.add('No CurveVault containers found');
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(parts.join(' · '))));
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _importSharedFiles() async {
    if (_busy) return;
    try {
      final files = await pickDocumentsFromFolder(
        context,
        title: 'Import Shared Files',
        filter: (document) => document.name.toLowerCase().endsWith('.cvlt'),
      );
      if (!mounted || files == null) return;
      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No .cvlt files found in that folder')),
        );
        return;
      }
      final summary = await _vault.importFiles(files);
      if (!mounted) return;
      final parts = <String>[];
      if (summary.locked > 0) {
        parts.add(
          'Imported ${summary.locked} file${summary.locked == 1 ? '' : 's'}',
        );
      }
      if (summary.failures.isNotEmpty) {
        parts.add('${summary.failures.length} could not be read');
      }
      if (parts.isEmpty) {
        parts.add('No CurveVault containers selected');
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(parts.join(' · '))));
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    final text = error.toString();
    final message = text.contains('storage_error: ')
        ? text.split('storage_error: ').last
        : text.startsWith('Exception: ')
        ? text.substring(11)
        : text;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showFailures(
    List<String> failures, {
    String title = 'Could not delete every file',
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).scaffoldBackgroundColor,
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: failures
                .map(
                  (failure) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      failure,
                      style: const TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_vault, _transfer]),
      builder: (context, _) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final primaryColor = Theme.of(context).primaryColor;
        final secondaryTextColor = isDark ? Colors.white38 : Colors.black38;
        final dividerColor = Theme.of(context).dividerColor;
        final entries = _filteredEntries;
        final busy = _busy;

        if (_selecting) {
          final existingIds = entries.map((entry) => entry.id).toSet();
          final stale = _selectedIds
              .where((id) => !existingIds.contains(id))
              .toList(growable: false);
          if (stale.isNotEmpty) {
            // Keep the selection consistent if a background operation removes
            // an entry. Scheduling avoids mutating state during build.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                for (final id in stale) {
                  _selectedIds.remove(id);
                }
              });
            });
          }
        }

        final restorableSelection = _selectedEntries
            .where((entry) => !entry.isReceived)
            .toList(growable: false);

        return Scaffold(
          appBar: AppBar(
            leading: _selecting
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _clearSelection,
                  )
                : null,
            title: Text(
              _selecting ? '${_selectedIds.length} selected' : 'Vault',
            ),
            actions: [
              if (_selecting) ...[
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: 'Select all',
                  onPressed: busy ? null : _toggleSelectAll,
                ),
                IconButton(
                  icon: const Icon(Icons.restore),
                  tooltip: 'Restore selected',
                  onPressed: busy || restorableSelection.isEmpty
                      ? null
                      : () => _restoreEntries(restorableSelection),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  color: Colors.redAccent,
                  tooltip: 'Delete selected',
                  onPressed: busy || _selectedIds.isEmpty
                      ? null
                      : () => _deleteEntries(_selectedEntries),
                ),
              ] else
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, color: primaryColor),
                  onSelected: (value) {
                    if (value == 'recover') _recoverFolder();
                    if (value == 'import') _importSharedFiles();
                  },
                  itemBuilder: (ctx) => const [
                    PopupMenuItem<String>(
                      value: 'import',
                      child: Text('Import Shared File'),
                    ),
                    PopupMenuItem<String>(
                      value: 'recover',
                      child: Text('Recover Folder'),
                    ),
                  ],
                ),
            ],
          ),
          body: Column(
            children: [
              if (busy)
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _vault.isBusy
                                  ? (_vault.currentLabel == null
                                        ? 'Working...'
                                        : 'Processing ${_vault.currentLabel}')
                                  : (_busyMessage ?? 'Working...'),
                              style: TextStyle(
                                fontSize: 13,
                                color: primaryColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (_vault.isBusy && _vault.total > 0)
                            Text(
                              '${_vault.completed}/${_vault.total}',
                              style: TextStyle(
                                fontSize: 12,
                                color: secondaryTextColor,
                              ),
                            ),
                        ],
                      ),
                    ),
                    LinearProgressIndicator(
                      value: _vault.isBusy && _vault.total > 0
                          ? (_vault.completed / _vault.total).clamp(0.0, 1.0)
                          : null,
                      minHeight: 2,
                      backgroundColor: isDark ? Colors.white12 : Colors.black12,
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    ),
                  ],
                ),
              if (_vault.indexWarning != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: dividerColor, width: 0.5),
                    ),
                  ),
                  child: Text(
                    _vault.indexWarning!,
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              if (_vault.recoveryNotice != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: dividerColor, width: 0.5),
                    ),
                  ),
                  child: Text(
                    _vault.recoveryNotice!,
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ListTile(
                enabled: !busy,
                leading: Icon(
                  Icons.send_outlined,
                  size: AppSizes.icon,
                  color: busy ? secondaryTextColor : primaryColor,
                ),
                title: Text(
                  'Send Secret File',
                  style: TextStyle(
                    fontSize: AppSizes.title,
                    color: busy ? secondaryTextColor : primaryColor,
                  ),
                ),
                subtitle: Text(
                  'Share a locked file directly with a friend',
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: AppSizes.subtitle,
                  ),
                ),
                onTap: busy ? null : _startSend,
              ),
              const Divider(height: 1),
              ListTile(
                enabled: !busy,
                leading: Icon(
                  Icons.download_outlined,
                  size: AppSizes.icon,
                  color: busy ? secondaryTextColor : primaryColor,
                ),
                title: Text(
                  'Receive Secret File',
                  style: TextStyle(
                    fontSize: AppSizes.title,
                    color: busy ? secondaryTextColor : primaryColor,
                  ),
                ),
                subtitle: Text(
                  'Scan a friend\'s QR code to receive a file',
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: AppSizes.subtitle,
                  ),
                ),
                onTap: busy ? null : _startReceive,
              ),
              const Divider(height: 1),
              if (_transfer.hasActive)
                Container(
                  width: double.infinity,
                  color: isDark
                      ? const Color(0xFF141414)
                      : const Color(0xFFF4F4F4),
                  padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.swap_horiz,
                        size: AppSizes.icon - 4,
                        color: primaryColor,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Transfer in progress',
                              style: TextStyle(
                                color: primaryColor,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              _transfer.activeLabel,
                              style: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _resumeTransfer,
                        child: Text(
                          'Resume',
                          style: TextStyle(color: primaryColor),
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final filter in _VaultFilter.values)
                      ChoiceChip(
                        label: Text(_filterLabel(filter)),
                        selected: _filter == filter,
                        labelStyle: TextStyle(
                          color: _filter == filter
                              ? (isDark ? Colors.black : Colors.white)
                              : primaryColor,
                          fontSize: 13,
                        ),
                        selectedColor: primaryColor,
                        backgroundColor: Colors.transparent,
                        side: BorderSide(
                          color: isDark ? Colors.white24 : Colors.black26,
                        ),
                        onSelected: busy
                            ? null
                            : (_) => setState(() {
                                _filter = filter;
                                _selectedIds.clear();
                              }),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? _EmptyState(
                        primaryColor: primaryColor,
                        secondaryTextColor: secondaryTextColor,
                        onRecover: busy ? null : _recoverFolder,
                        title: _emptyTitle,
                        subtitle: _emptySubtitle,
                      )
                    : ListView.separated(
                        itemCount: entries.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: dividerColor),
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          final selected = _selectedIds.contains(entry.id);
                          return ListTile(
                            selected: selected,
                            selectedTileColor: isDark
                                ? Colors.white10
                                : Colors.black12,
                            leading: _selecting
                                ? Icon(
                                    selected
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                    size: AppSizes.icon - 2,
                                    color: primaryColor,
                                  )
                                : Icon(
                                    entry.isReceived
                                        ? Icons.download_for_offline_outlined
                                        : _iconFor(entry.mime),
                                    size: AppSizes.icon - 2,
                                    color: primaryColor,
                                  ),
                            title: Text(
                              entry.name,
                              style: TextStyle(
                                fontSize: AppSizes.subtitle + 1,
                                color: primaryColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              entry.isReceived
                                  ? 'Received · ${_formatDate(entry.receivedAt ?? entry.addedAt)}'
                                  : _formatDate(entry.addedAt),
                              style: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 13,
                              ),
                            ),
                            trailing: Text(
                              _formatBytes(entry.size),
                              style: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 13,
                              ),
                            ),
                            onTap: busy
                                ? null
                                : _selecting
                                ? () => _toggleSelection(entry)
                                : () => _showActions(entry),
                            onLongPress: busy
                                ? null
                                : () {
                                    if (!_selecting) {
                                      _toggleSelection(entry);
                                    }
                                  },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  String get _emptyTitle {
    switch (_filter) {
      case _VaultFilter.all:
        return 'No encrypted files';
      case _VaultFilter.mine:
        return 'No locked files yet';
      case _VaultFilter.received:
        return 'No received files yet';
    }
  }

  String get _emptySubtitle {
    switch (_filter) {
      case _VaultFilter.all:
        return 'Files you lock stay in their original folder and disappear from the gallery.';
      case _VaultFilter.mine:
        return 'Files you lock yourself will appear here.';
      case _VaultFilter.received:
        return 'Secret files sent by friends will appear here after they are verified.';
    }
  }

  static String _filterLabel(_VaultFilter filter) {
    switch (filter) {
      case _VaultFilter.all:
        return 'All';
      case _VaultFilter.mine:
        return 'Mine';
      case _VaultFilter.received:
        return 'Received';
    }
  }

  static IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.videocam_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatDate(int milliseconds) {
    if (milliseconds <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.primaryColor,
    required this.secondaryTextColor,
    required this.onRecover,
    required this.title,
    required this.subtitle,
  });

  final Color primaryColor;
  final Color secondaryTextColor;
  final VoidCallback? onRecover;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock_outline,
                size: AppSizes.icon + 30,
                color: primaryColor,
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: TextStyle(
                  color: primaryColor,
                  fontSize: AppSizes.title,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: secondaryTextColor,
                  fontSize: AppSizes.subtitle,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 28),
              TextButton(
                onPressed: onRecover,
                child: Text(
                  'Recover Folder',
                  style: TextStyle(color: primaryColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
