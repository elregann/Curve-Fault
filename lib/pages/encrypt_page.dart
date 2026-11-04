import 'package:flutter/material.dart';

import '../services/native_storage.dart';
import '../services/vault_service.dart';
import '../theme/app_sizes.dart';
import '../widgets/document_picker.dart';

/// Screen for locking files and folders in place with CurveVault.
class EncryptPage extends StatefulWidget {
  const EncryptPage({super.key});

  @override
  State<EncryptPage> createState() => _EncryptPageState();
}

class _EncryptPageState extends State<EncryptPage> {
  List<NativeDocument> _pickedFiles = const [];
  NativeDocument? _pickedFolder;
  String? _pickerError;

  VaultService get _vault => VaultService.instance;

  bool get _hasSelection =>
      _pickedFiles.isNotEmpty || _pickedFolder != null;

  Future<void> _pickFiles() async {
    if (_vault.isBusy) return;
    try {
      final files = await pickDocumentsFromFolder(
        context,
        title: 'Select Files to Lock',
        filter: (document) =>
            !document.name.toLowerCase().endsWith('.cvlt'),
      );
      if (!mounted || files == null) return;
      if (files.isEmpty) {
        setState(
          () => _pickerError = 'No lockable files were found in that folder',
        );
        return;
      }
      setState(() {
        _pickedFiles = files;
        _pickedFolder = null;
        _pickerError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _pickerError = _messageFor(error));
    }
  }

  Future<void> _pickFolder() async {
    if (_vault.isBusy) return;
    try {
      final folder = await NativeStorage.pickFolder();
      if (!mounted || folder == null) return;
      setState(() {
        _pickedFolder = folder;
        _pickedFiles = const [];
        _pickerError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _pickerError = _messageFor(error));
    }
  }

  Future<void> _lockSelection() async {
    if (_vault.isBusy || !_hasSelection) return;
    final folder = _pickedFolder;
    final files = _pickedFiles;
    setState(() => _pickerError = null);

    late final VaultLockSummary summary;
    try {
      summary = folder != null
          ? await _vault.lockFolder(folder)
          : await _vault.lockDocuments(files);
    } catch (error) {
      if (mounted) {
        setState(() => _pickerError = _messageFor(error));
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _pickedFiles = const [];
      _pickedFolder = null;
    });

    final parts = <String>[];
    if (summary.locked > 0) {
      parts.add('Locked ${summary.locked} file${summary.locked == 1 ? '' : 's'}');
    }
    if (summary.failures.isNotEmpty) {
      parts.add('${summary.failures.length} failed');
    }
    if (parts.isEmpty) {
      parts.add('Nothing was locked');
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(parts.join(' · ')),
        action: summary.failures.isEmpty
            ? null
            : SnackBarAction(
                label: 'Details',
                onPressed: () => _showFailures(summary.failures),
              ),
      ),
    );
  }

  Future<void> _showFailures(List<String> failures) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).scaffoldBackgroundColor,
        title: const Text('Some files were not locked'),
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

  void _removeFile(int index) {
    final next = List<NativeDocument>.from(_pickedFiles)..removeAt(index);
    setState(() => _pickedFiles = next);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryTextColor = isDark ? Colors.white38 : Colors.black38;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Encrypt'),
      ),
      body: AnimatedBuilder(
        animation: _vault,
        builder: (context, _) {
          final busy = _vault.isBusy;
          final total = _vault.total;
          final progress = total > 0
              ? (_vault.completed / total).clamp(0.0, 1.0)
              : null;

          return ListView(
            children: [
              if (busy) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSizes.listPaddingHorizontal,
                    16,
                    AppSizes.listPaddingHorizontal,
                    8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _vault.currentLabel == null
                            ? 'Working...'
                            : 'Locking ${_vault.currentLabel}',
                        style: TextStyle(
                          fontSize: AppSizes.subtitle + 1,
                          color: primaryColor,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor:
                            isDark ? Colors.white12 : Colors.black12,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(primaryColor),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        total > 0
                            ? '${_vault.completed} of $total'
                            : 'Scanning folder...',
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
              ],

              ListTile(
                enabled: !busy,
                leading: Icon(
                  Icons.insert_drive_file_outlined,
                  size: AppSizes.icon,
                  color: busy ? secondaryTextColor : primaryColor,
                ),
                title: Text(
                  'Select Files',
                  style: TextStyle(
                    fontSize: AppSizes.title,
                    color: busy ? secondaryTextColor : primaryColor,
                  ),
                ),
                subtitle: Text(
                  _pickedFiles.isEmpty
                      ? 'Choose one or more files to lock'
                      : '${_pickedFiles.length} file${_pickedFiles.length == 1 ? '' : 's'} selected',
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: AppSizes.subtitle,
                  ),
                ),
                onTap: busy ? null : _pickFiles,
              ),
              const Divider(height: 1),
              ListTile(
                enabled: !busy,
                leading: Icon(
                  Icons.folder_outlined,
                  size: AppSizes.icon,
                  color: busy ? secondaryTextColor : primaryColor,
                ),
                title: Text(
                  'Select Folder',
                  style: TextStyle(
                    fontSize: AppSizes.title,
                    color: busy ? secondaryTextColor : primaryColor,
                  ),
                ),
                subtitle: Text(
                  _pickedFolder == null
                      ? 'Lock every file in a folder'
                      : _pickedFolder!.name,
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: AppSizes.subtitle,
                  ),
                ),
                onTap: busy ? null : _pickFolder,
              ),

              if (_pickerError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSizes.listPaddingHorizontal,
                    16,
                    AppSizes.listPaddingHorizontal,
                    0,
                  ),
                  child: Text(
                    _pickerError!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ),

              if (_pickedFolder != null) ...[
                const SizedBox(height: AppSizes.sectionSpacing),
                _SectionLabel(
                  label: 'FOLDER',
                  color: secondaryTextColor,
                ),
                ListTile(
                  leading: Icon(
                    Icons.folder,
                    size: AppSizes.icon,
                    color: primaryColor,
                  ),
                  title: Text(
                    _pickedFolder!.name,
                    style: TextStyle(
                      fontSize: AppSizes.subtitle + 1,
                      color: primaryColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _pickedFolder!.relativePath,
                    style: TextStyle(
                      color: secondaryTextColor,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: Icon(
                      Icons.close,
                      size: AppSizes.icon - 6,
                      color: secondaryTextColor,
                    ),
                    onPressed: busy
                        ? null
                        : () => setState(() => _pickedFolder = null),
                  ),
                ),
              ],

              if (_pickedFiles.isNotEmpty) ...[
                const SizedBox(height: AppSizes.sectionSpacing),
                _SectionLabel(
                  label: 'FILES',
                  color: secondaryTextColor,
                ),
                for (var i = 0; i < _pickedFiles.length; i++)
                  ListTile(
                    leading: Icon(
                      _iconFor(_pickedFiles[i].mime),
                      size: AppSizes.icon - 2,
                      color: primaryColor,
                    ),
                    title: Text(
                      _pickedFiles[i].name,
                      style: TextStyle(
                        fontSize: AppSizes.subtitle + 1,
                        color: primaryColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _formatBytes(_pickedFiles[i].size),
                      style: TextStyle(
                        color: secondaryTextColor,
                        fontSize: 13,
                      ),
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.close,
                        size: AppSizes.icon - 6,
                        color: secondaryTextColor,
                      ),
                      onPressed: busy ? null : () => _removeFile(i),
                    ),
                  ),
              ],

              if (_hasSelection) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSizes.listPaddingHorizontal,
                    vertical: 16,
                  ),
                  child: Divider(height: 1),
                ),
                ListTile(
                  enabled: !busy,
                  leading: Icon(
                    Icons.lock_outline,
                    size: AppSizes.icon,
                    color: busy ? secondaryTextColor : primaryColor,
                  ),
                  title: Text(
                    busy
                        ? 'Locking...'
                        : _pickedFolder != null
                            ? 'Lock Folder'
                            : 'Lock ${_pickedFiles.length} File${_pickedFiles.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: AppSizes.title,
                      color: busy ? secondaryTextColor : primaryColor,
                    ),
                  ),
                  subtitle: Text(
                    'Files stay in place, are renamed to .cvlt, and disappear from the gallery.',
                    style: TextStyle(
                      color: secondaryTextColor,
                      fontSize: AppSizes.subtitle,
                      height: 1.35,
                    ),
                  ),
                  trailing: Icon(
                    Icons.arrow_forward,
                    color: busy ? secondaryTextColor : primaryColor,
                    size: AppSizes.icon,
                  ),
                  onTap: busy ? null : _lockSelection,
                ),
              ],

              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
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

  static IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.videocam_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _messageFor(Object error) {
    final text = error.toString();
    if (text.contains('storage_error: ')) {
      return text.split('storage_error: ').last;
    }
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSizes.listPaddingHorizontal,
        12,
        16,
        4,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
