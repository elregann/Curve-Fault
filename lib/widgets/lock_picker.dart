import 'dart:math';

import 'package:flutter/material.dart';

import '../services/lock_access.dart';
import '../services/native_storage.dart';
import '../theme/app_sizes.dart';

typedef FilesPicker = Future<List<NativeDocument>> Function();
typedef AccessResolver =
    Future<List<LockCandidate>> Function(List<NativeDocument> documents);
typedef AccessRequester = Future<bool> Function(String folderKey);

/// Opens the system file picker, then shows a confirmation sheet where the
/// chosen files can still be unchecked. Returns the files that are ready to
/// lock, `null` when nothing was picked, or an empty list when every picked
/// file was already locked.
Future<List<NativeDocument>?> pickFilesToLock(
  BuildContext context, {
  FilesPicker? pick,
  AccessResolver? resolve,
  AccessRequester? requestAccess,
}) async {
  final pickFiles = pick ?? NativeStorage.pickFiles;
  final resolver = resolve ?? LockAccess.resolveAll;
  final requester = requestAccess ?? _requestFolderAccess;

  final picked = await pickFiles();
  if (picked.isEmpty) return null;
  if (!context.mounted) return null;

  final lockable = picked
      .where((document) => !document.name.toLowerCase().endsWith('.cvlt'))
      .toList(growable: false);
  final skipped = picked.length - lockable.length;
  if (lockable.isEmpty) return const [];

  final candidates = await _withLoader(context, () => resolver(lockable));
  if (!context.mounted) return null;

  return showModalBottomSheet<List<NativeDocument>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    builder: (ctx) => _LockSheet(
      originals: lockable,
      initial: candidates,
      resolve: resolver,
      requestAccess: requester,
      skipped: skipped,
    ),
  );
}

Future<bool> _requestFolderAccess(String folderKey) async {
  final folder = await NativeStorage.pickFolder(initialDocId: folderKey);
  return folder != null;
}

Future<T> _withLoader<T>(
  BuildContext context,
  Future<T> Function() task,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final color = Theme.of(context).primaryColor;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator(color: color)),
    ),
  );
  try {
    return await task();
  } finally {
    navigator.pop();
  }
}

class _LockSheet extends StatefulWidget {
  const _LockSheet({
    required this.originals,
    required this.initial,
    required this.resolve,
    required this.requestAccess,
    required this.skipped,
  });

  final List<NativeDocument> originals;
  final List<LockCandidate> initial;
  final AccessResolver resolve;
  final AccessRequester requestAccess;
  final int skipped;

  @override
  State<_LockSheet> createState() => _LockSheetState();
}

class _LockSheetState extends State<_LockSheet> {
  late List<LockCandidate> _candidates;
  final Set<String> _unchecked = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _candidates = widget.initial;
  }

  Future<void> _allow(String folderKey) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final granted = await widget.requestAccess(folderKey);
      if (!mounted || !granted) return;
      final next = await widget.resolve(widget.originals);
      if (!mounted) return;
      setState(() {
        _candidates = next;
        final stillWaiting = next.any(
          (candidate) =>
              candidate.status == AccessStatus.needsAccess &&
              candidate.folderKey == folderKey,
        );
        if (stillWaiting) {
          _error =
              'That folder does not include these files. '
              'Choose the folder named above.';
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = _messageFor(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle(LockCandidate candidate, bool? checked) {
    setState(() {
      if (checked == true) {
        _unchecked.remove(candidate.sourceUri);
      } else {
        _unchecked.add(candidate.sourceUri);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;
    final height = min(
      MediaQuery.of(context).size.height * 0.8,
      MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top,
    );

    final chosen = _candidates
        .where(
          (candidate) =>
              candidate.status == AccessStatus.ready &&
              !_unchecked.contains(candidate.sourceUri),
        )
        .toList(growable: false);
    final groups = LockAccess.groupNeedingAccess(_candidates);
    final unsupported = _candidates
        .where((candidate) => candidate.status == AccessStatus.unsupported)
        .length;

    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                'Select Files to Lock',
                style: TextStyle(
                  fontSize: AppSizes.title,
                  color: primaryColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '${chosen.length} of ${_candidates.length} '
                'file${_candidates.length == 1 ? '' : 's'} ready to lock',
                style: TextStyle(color: secondaryColor, fontSize: 13),
              ),
            ),
            if (_busy)
              LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: isDark ? Colors.white12 : Colors.black12,
                valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
              ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final entry in groups.entries)
                    _Notice(
                      text:
                          '${entry.value.length} '
                          'file${entry.value.length == 1 ? '' : 's'} in '
                          '"${entry.value.first.folderName}" need access',
                      actionLabel: 'Allow access',
                      onAction: _busy ? null : () => _allow(entry.key),
                    ),
                  if (unsupported > 0)
                    _Notice(
                      text:
                          '$unsupported file${unsupported == 1 ? '' : 's'} '
                          'cannot be locked here',
                    ),
                  if (widget.skipped > 0)
                    _Notice(
                      text:
                          '${widget.skipped} already locked '
                          'file${widget.skipped == 1 ? '' : 's'} skipped',
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ),
                  for (final candidate in _candidates)
                    CheckboxListTile(
                      value:
                          candidate.status == AccessStatus.ready &&
                          !_unchecked.contains(candidate.sourceUri),
                      onChanged:
                          candidate.status == AccessStatus.ready && !_busy
                          ? (value) => _toggle(candidate, value)
                          : null,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: primaryColor,
                      checkColor: isDark ? Colors.black : Colors.white,
                      title: Text(
                        candidate.document.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppSizes.subtitle + 1,
                          color: primaryColor,
                        ),
                      ),
                      subtitle: Text(
                        _subtitleFor(candidate),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: secondaryColor),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Cancel',
                      style: TextStyle(color: secondaryColor),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: chosen.isEmpty || _busy
                        ? null
                        : () => Navigator.of(context).pop(
                            chosen
                                .map((candidate) => candidate.document)
                                .toList(growable: false),
                          ),
                    child: Text(
                      chosen.isEmpty ? 'Select Files' : 'Add ${chosen.length}',
                      style: TextStyle(
                        color: chosen.isEmpty ? secondaryColor : primaryColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _subtitleFor(LockCandidate candidate) {
    switch (candidate.status) {
      case AccessStatus.ready:
        return '${candidate.document.relativePath} · '
            '${_formatBytes(candidate.document.size)}';
      case AccessStatus.needsAccess:
        return 'Needs access to ${candidate.folderName}';
      case AccessStatus.unsupported:
        return candidate.reason ?? 'Cannot be locked here';
    }
  }

  static String _messageFor(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
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
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.actionLabel, this.onAction});

  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 12, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.orangeAccent,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              child: Text(
                actionLabel!,
                style: TextStyle(color: Theme.of(context).primaryColor),
              ),
            ),
        ],
      ),
    );
  }
}
