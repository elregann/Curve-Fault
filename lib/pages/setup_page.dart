import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../services/seed_service.dart';
import '../services/session_service.dart';
import '../services/vault_service.dart';
import '../theme/app_sizes.dart';
import '../main.dart';

/// First-time onboarding screen where the user establishes a vault passphrase.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _passController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;
  bool _isLoading = false;
  String? _error;

  Future<void> _create() async {
    final pass = _passController.text.trim();
    final confirm = _confirmController.text.trim();

    if (pass.length < SeedService.minPassphraseLength) {
      setState(
        () => _error =
            'Passphrase must be at least ${SeedService.minPassphraseLength} characters',
      );
      return;
    }
    if (pass != confirm) {
      setState(() => _error = 'Passphrases do not match');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final seed = await SeedService.setup(pass);
      SessionService.setSession(seed);
      await VaultService.instance.unlock(seed);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainShell()),
      );
    } catch (e) {
      setState(() {
        _error = 'Failed to create seed';
        _isLoading = false;
      });
    }
  }

  Future<void> _restore() async {
    final pass = _passController.text.trim();
    final confirm = _confirmController.text.trim();

    if (pass.length < SeedService.minPassphraseLength) {
      setState(
        () => _error =
            'Passphrase must be at least ${SeedService.minPassphraseLength} characters',
      );
      return;
    }
    if (pass != confirm) {
      setState(() => _error = 'Passphrases do not match');
      return;
    }

    final seedController = TextEditingController();
    String? dialogError;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;

    final hex = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            title: const Text('Restore Master Seed'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enter the 64-character hex master seed you exported earlier. '
                    'It will be protected by the passphrase above.',
                    style: TextStyle(
                      color: secondaryColor,
                      fontSize: AppSizes.subtitle,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: seedController,
                    maxLines: 3,
                    style: TextStyle(
                      color: primaryColor,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Master Seed (hex)',
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
                  if (dialogError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      dialogError!,
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
                child: Text(
                  'Cancel',
                  style: TextStyle(color: secondaryColor),
                ),
              ),
              TextButton(
                onPressed: () {
                  final normalized =
                      seedController.text.replaceAll(RegExp(r'\s'), '').toLowerCase();
                  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
                    setDialogState(
                      () => dialogError =
                          'Enter a 64-character hex master seed',
                    );
                    return;
                  }
                  Navigator.of(ctx).pop(normalized);
                },
                child: Text(
                  'Restore',
                  style: TextStyle(color: primaryColor),
                ),
              ),
            ],
          );
        },
      ),
    );
    seedController.dispose();
    if (hex == null || !mounted) return;

    final seed = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      seed[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await SeedService.restore(seed: seed, passphrase: pass);
      SessionService.setSession(seed);
      await VaultService.instance.unlock(seed);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainShell()),
      );
    } catch (e) {
      setState(() {
        _error = 'Failed to restore seed';
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _passController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  InputDecoration _inputDecoration(BuildContext context, String label, {Widget? suffix}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hintColor = isDark ? Colors.white54 : Colors.black54;
    final borderColor = isDark ? Colors.white24 : Colors.black26;
    final focusedColor = isDark ? Colors.white70 : Colors.black87;

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: hintColor,
        fontSize: AppSizes.subtitle,
      ),
      floatingLabelStyle: TextStyle(
        color: focusedColor,
        fontSize: AppSizes.subtitle,
      ),
      enabledBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      focusedBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: focusedColor, width: 1),
      ),
      border: UnderlineInputBorder(
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      suffixIcon: suffix,
      filled: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = Theme.of(context).primaryColor;
    final secondaryTextColor = isDark ? Colors.white54 : Colors.black54;
    final disabledTextColor = isDark ? Colors.white38 : Colors.black38;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Setup'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSizes.listPaddingHorizontal,
        ),
        children: [
          const SizedBox(height: 24),

          Text(
            'Create Passphrase',
            style: TextStyle(
              fontSize: AppSizes.title,
              fontWeight: FontWeight.w500,
              color: primaryTextColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This passphrase protects your Master Seed. Use at least '
            '${SeedService.minPassphraseLength} characters and make sure you '
            'remember it.',
            style: TextStyle(
              color: secondaryTextColor,
              fontSize: AppSizes.subtitle,
              height: 1.4,
            ),
          ),

          const SizedBox(height: 40),

          // Passphrase Input
          TextField(
            controller: _passController,
            obscureText: _obscure,
            style: TextStyle(
              color: primaryTextColor,
              fontSize: AppSizes.subtitle + 1,
            ),
            cursorColor: primaryTextColor,
            decoration: _inputDecoration(
              context,
              'Passphrase',
              suffix: IconButton(
                icon: Icon(
                  _obscure ? Icons.visibility_off : Icons.visibility,
                  color: secondaryTextColor,
                  size: AppSizes.icon - 2,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                hoverColor: Colors.transparent,
                focusColor: Colors.transparent,
              ),
            ),
          ),

          const SizedBox(height: 28),

          // Confirm Passphrase Input
          TextField(
            controller: _confirmController,
            obscureText: _obscure,
            style: TextStyle(
              color: primaryTextColor,
              fontSize: AppSizes.subtitle + 1,
            ),
            cursorColor: primaryTextColor,
            decoration: _inputDecoration(context, 'Confirm Passphrase'),
          ),

          if (_error != null) ...[
            const SizedBox(height: 20),
            Text(
              _error!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: AppSizes.subtitle,
              ),
            ),
          ],

          const SizedBox(height: 48),

          // Create Action Button
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              _isLoading ? 'Creating...' : 'Create',
              style: TextStyle(
                fontSize: AppSizes.title,
                color: _isLoading ? disabledTextColor : primaryTextColor,
              ),
            ),
            trailing: _isLoading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: secondaryTextColor,
                    ),
                  )
                : Icon(
                    Icons.arrow_forward,
                    color: primaryTextColor,
                    size: AppSizes.icon,
                  ),
            onTap: _isLoading ? null : _create,
          ),

          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Restore Existing Seed',
              style: TextStyle(
                fontSize: AppSizes.subtitle + 1,
                color: _isLoading ? disabledTextColor : primaryTextColor,
              ),
            ),
            subtitle: Text(
              'Reuse a master seed backup from another install.',
              style: TextStyle(
                color: secondaryTextColor,
                fontSize: 13,
              ),
            ),
            onTap: _isLoading ? null : _restore,
          ),
        ],
      ),
    );
  }
}
