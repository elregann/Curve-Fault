import 'package:flutter/material.dart';
import '../theme/app_sizes.dart';

/// Screen facilitating single file and bulk directory encryption using Curve256189.
class EncryptPage extends StatelessWidget {
  const EncryptPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryTextColor = isDark ? Colors.white38 : Colors.black38;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Encrypt'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(
              Icons.insert_drive_file_outlined,
              size: AppSizes.icon,
              color: primaryColor,
            ),
            title: Text(
              'Select File',
              style: TextStyle(
                fontSize: AppSizes.title,
                color: primaryColor,
              ),
            ),
            subtitle: Text(
              'Encrypt a single file',
              style: TextStyle(
                color: secondaryTextColor,
                fontSize: AppSizes.subtitle,
              ),
            ),
            onTap: () {
              // File picker integration stub
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              Icons.folder_outlined,
              size: AppSizes.icon,
              color: primaryColor,
            ),
            title: Text(
              'Select Folder',
              style: TextStyle(
                fontSize: AppSizes.title,
                color: primaryColor,
              ),
            ),
            subtitle: Text(
              'Encrypt all files in a folder',
              style: TextStyle(
                color: secondaryTextColor,
                fontSize: AppSizes.subtitle,
              ),
            ),
            onTap: () {
              // Directory picker integration stub
            },
          ),
        ],
      ),
    );
  }
}
