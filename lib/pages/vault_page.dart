import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/vault_entry.dart';
import '../services/native_storage.dart';
import '../services/vault_service.dart';
import '../theme/app_sizes.dart';
import '../widgets/document_picker.dart';

/// Screen presenting the encrypted files tracked by the vault index.
class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final Set<String> _selectedIds = <String>{};
  String? _busyMessage;

  VaultService get _vault => VaultService.instance;

  bool get _selecting => _selectedIds.isNotEmpty;
  bool get _busy => _busyMessage != null || _vault.isBusy;

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
                ListTile(
                  leading: Icon(Icons.restore, color: primaryColor),
                  title: Text('Restore', style: TextStyle(color: primaryColor)),
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

  void _showFailures(List<String> failures) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).scaffoldBackgroundColor,
        title: const Text('Could not delete every file'),
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
      animation: _vault,
      builder: (context, _) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final primaryColor = Theme.of(context).primaryColor;
        final secondaryTextColor = isDark ? Colors.white38 : Colors.black38;
        final dividerColor = Theme.of(context).dividerColor;
        final entries = _vault.entries;
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
              Expanded(
                child: entries.isEmpty
                    ? _EmptyState(
                        primaryColor: primaryColor,
                        secondaryTextColor: secondaryTextColor,
                        onRecover: busy ? null : _recoverFolder,
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
                                    _iconFor(entry.mime),
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
                              '${_formatBytes(entry.size)} · ${_formatDate(entry.addedAt)}',
                              style: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 13,
                              ),
                            ),
                            trailing: _selecting
                                ? null
                                : Icon(
                                    Icons.more_vert,
                                    size: AppSizes.icon - 6,
                                    color: secondaryTextColor,
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
  });

  final Color primaryColor;
  final Color secondaryTextColor;
  final VoidCallback? onRecover;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
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
              'No encrypted files',
              style: TextStyle(
                color: primaryColor,
                fontSize: AppSizes.title,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Files you lock stay in their original folder and disappear from the gallery.',
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
    );
  }
}
