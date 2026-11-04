import 'dart:math';

import 'package:flutter/material.dart';

import '../services/native_storage.dart';
import '../theme/app_sizes.dart';

/// Narrows the picker list by file name and, optionally, drops files that
/// live in subfolders.
List<NativeDocument> filterPickerFiles(
  List<NativeDocument> files, {
  required String query,
  required bool includeSubfolders,
}) {
  final needle = query.trim().toLowerCase();
  return files
      .where((document) {
        if (!includeSubfolders && document.relativePath.contains('/')) {
          return false;
        }
        if (needle.isEmpty) return true;
        return document.name.toLowerCase().contains(needle);
      })
      .toList(growable: false);
}

/// Lets the user grant access to a folder and then pick one or more files
/// inside it. Selecting through a folder keeps a persistable tree grant, which
/// is required to keep opening the renamed `.cvlt` containers later.
Future<List<NativeDocument>?> pickDocumentsFromFolder(
  BuildContext context, {
  required String title,
  bool Function(NativeDocument document)? filter,
}) async {
  final folder = await NativeStorage.pickFolder();
  if (folder == null) return null;
  if (!context.mounted) return null;

  final navigator = Navigator.of(context, rootNavigator: true);
  final loaderColor = Theme.of(context).primaryColor;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator(color: loaderColor)),
    ),
  );

  var all = const <NativeDocument>[];
  try {
    all = await NativeStorage.listDocuments(folder.uri);
  } finally {
    navigator.pop();
  }

  final files = all
      .where((document) => !document.isDirectory)
      .where((document) => !isHiddenPath(document.relativePath))
      .where(filter ?? (document) => true)
      .toList(growable: false);

  if (!context.mounted) return null;
  if (files.isEmpty) return const [];

  final selected = <String>{};
  var query = '';
  var includeSubfolders = true;
  final hasNested = files.any((document) => document.relativePath.contains('/'));
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final primaryColor = Theme.of(context).primaryColor;
  final secondaryColor = isDark ? Colors.white54 : Colors.black54;
  final lineColor = isDark ? Colors.white24 : Colors.black26;

  final result = await showModalBottomSheet<List<NativeDocument>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          final media = MediaQuery.of(ctx);
          final available =
              media.size.height - media.viewInsets.bottom - media.padding.top;
          final height = min(media.size.height * 0.8, available);
          final visible = filterPickerFiles(
            files,
            query: query,
            includeSubfolders: includeSubfolders,
          );
          final allVisibleSelected =
              visible.isNotEmpty &&
              visible.every((document) => selected.contains(document.uri));

          return Padding(
            padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
            child: SafeArea(
              child: SizedBox(
                height: height,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                      child: Text(
                        title,
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
                        '${folder.name} · ${visible.length} '
                        'file${visible.length == 1 ? '' : 's'}',
                        style: TextStyle(color: secondaryColor, fontSize: 13),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: TextField(
                        onChanged: (value) =>
                            setSheetState(() => query = value),
                        style: TextStyle(color: primaryColor, fontSize: 14),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search name',
                          hintStyle: TextStyle(
                            color: secondaryColor,
                            fontSize: 14,
                          ),
                          prefixIcon: Icon(
                            Icons.search,
                            size: 18,
                            color: secondaryColor,
                          ),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: lineColor),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: primaryColor),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: visible.isEmpty
                                ? null
                                : () => setSheetState(() {
                                    final uris = visible.map(
                                      (document) => document.uri,
                                    );
                                    if (allVisibleSelected) {
                                      selected.removeAll(uris);
                                    } else {
                                      selected.addAll(uris);
                                    }
                                  }),
                            child: Text(
                              allVisibleSelected ? 'Clear all' : 'Select all',
                              style: TextStyle(color: primaryColor),
                            ),
                          ),
                          const Spacer(),
                          if (hasNested)
                            TextButton(
                              onPressed: () => setSheetState(
                                () => includeSubfolders = !includeSubfolders,
                              ),
                              child: Text(
                                'Subfolders: ${includeSubfolders ? 'on' : 'off'}',
                                style: TextStyle(color: secondaryColor),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: visible.isEmpty
                          ? Center(
                              child: Text(
                                'No matching files',
                                style: TextStyle(color: secondaryColor),
                              ),
                            )
                          : ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (ctx, index) {
                                final document = visible[index];
                                final checked = selected.contains(document.uri);
                                return CheckboxListTile(
                                  value: checked,
                                  onChanged: (value) {
                                    setSheetState(() {
                                      if (value == true) {
                                        selected.add(document.uri);
                                      } else {
                                        selected.remove(document.uri);
                                      }
                                    });
                                  },
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  activeColor: primaryColor,
                                  checkColor: isDark
                                      ? Colors.black
                                      : Colors.white,
                                  title: Text(
                                    document.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: AppSizes.subtitle + 1,
                                      color: primaryColor,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${document.relativePath} · '
                                    '${_formatBytes(document.size)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: secondaryColor,
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: Text(
                              'Cancel',
                              style: TextStyle(color: secondaryColor),
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: selected.isEmpty
                                ? null
                                : () => Navigator.of(ctx).pop(
                                    files
                                        .where(
                                          (document) =>
                                              selected.contains(document.uri),
                                        )
                                        .toList(growable: false),
                                  ),
                            child: Text(
                              selected.isEmpty
                                  ? 'Select Files'
                                  : 'Add ${selected.length}',
                              style: TextStyle(
                                color: selected.isEmpty
                                    ? secondaryColor
                                    : primaryColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );

  return result;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
