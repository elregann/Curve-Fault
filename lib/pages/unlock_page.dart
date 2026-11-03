import 'package:flutter/material.dart';
import '../services/seed_service.dart';
import '../services/session_service.dart';
import '../theme/app_sizes.dart';
import '../main.dart';

/// Screen presented when returning to the application to unlock the master vault.
class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _passController = TextEditingController();
  bool _obscure = true;
  bool _isLoading = false;
  String? _error;

  Future<void> _unlock() async {
    final pass = _passController.text.trim();

    if (pass.isEmpty) {
      setState(() => _error = 'Please enter your passphrase');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final seed = await SeedService.getMasterSeed(pass);

      if (seed == null) {
        setState(() {
          _error = 'Wrong passphrase';
          _isLoading = false;
        });
        return;
      }

      // Initialize runtime in-memory session with decrypted master seed
      SessionService.setSession(seed);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainShell()),
      );
    } catch (e) {
      setState(() {
        _error = 'Failed to unlock';
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _passController.dispose();
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
        title: const Text('Unlock'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSizes.listPaddingHorizontal,
        ),
        children: [
          const SizedBox(height: 24),

          Text(
            'Enter Passphrase',
            style: TextStyle(
              fontSize: AppSizes.title,
              fontWeight: FontWeight.w500,
              color: primaryTextColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Enter your passphrase to unlock the vault.',
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

          // Unlock Action Button
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              _isLoading ? 'Unlocking...' : 'Unlock',
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
            onTap: _isLoading ? null : _unlock,
          ),
        ],
      ),
    );
  }
}
