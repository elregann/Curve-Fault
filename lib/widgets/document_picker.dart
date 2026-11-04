import 'package:flutter/material.dart';

import '../services/native_storage.dart';
import '../theme/app_sizes.dart';

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

  final all = await NativeStorage.listDocuments(folder.uri);
  final files = all
      .where((document) => !document.isDirectory)
      .where((document) => !document.name.startsWith('.'))
      .where(filter ?? (document) => true)
      .toList(growable: false);

  if (!context.mounted) return null;
  if (files.isEmpty) return const [];

  final selected = <String>{};
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final primaryColor = Theme.of(context).primaryColor;
  final secondaryColor = isDark ? Colors.white54 : Colors.black54;

  final result = await showModalBottomSheet<List<NativeDocument>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          final height = MediaQuery.of(ctx).size.height * 0.8;
          return SafeArea(
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
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text(
                      '${folder.name} · ${files.length} '
                      'file${files.length == 1 ? '' : 's'}',
                      style: TextStyle(color: secondaryColor, fontSize: 13),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: files.length,
                      itemBuilder: (ctx, index) {
                        final document = files[index];
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
                          controlAffinity: ListTileControlAffinity.leading,
                          activeColor: primaryColor,
                          checkColor: isDark ? Colors.black : Colors.white,
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
