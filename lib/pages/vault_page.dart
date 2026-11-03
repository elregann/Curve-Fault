import 'package:flutter/material.dart';
import '../theme/app_sizes.dart';

/// Screen presenting the list of encrypted vault records and assets.
class VaultPage extends StatelessWidget {
  const VaultPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryTextColor = isDark ? Colors.white38 : Colors.black38;
    final iconColor = isDark ? Colors.white24 : Colors.black26;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vault'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_outline,
              size: AppSizes.icon + 30,
              color: iconColor,
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
              'Files you encrypt will appear here',
              style: TextStyle(
                color: secondaryTextColor,
                fontSize: AppSizes.subtitle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
