import 'package:flutter/material.dart';

import '../theme/app_sizes.dart';

/// A tappable row on the unlock page that swaps its arrow for a spinner
/// while its own action is running.
class UnlockActionTile extends StatelessWidget {
  const UnlockActionTile({
    super.key,
    required this.title,
    required this.titleSize,
    required this.loading,
    required this.onTap,
    this.leading,
    this.dimWhenLoading = false,
  });

  final String title;
  final double titleSize;
  final bool loading;
  final VoidCallback? onTap;
  final Widget? leading;
  final bool dimWhenLoading;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;
    final secondary = isDark ? Colors.white54 : Colors.black54;
    final dimmed = isDark ? Colors.white38 : Colors.black38;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: Text(
        title,
        style: TextStyle(
          fontSize: titleSize,
          color: loading && dimWhenLoading ? dimmed : primary,
        ),
      ),
      trailing: loading
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: secondary,
              ),
            )
          : Icon(Icons.arrow_forward, color: primary, size: AppSizes.icon),
      onTap: onTap,
    );
  }
}
