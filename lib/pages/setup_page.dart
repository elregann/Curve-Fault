import 'package:flutter/material.dart';
import '../services/seed_service.dart';
import '../services/session_service.dart';
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

    if (pass.length < 8) {
      setState(() => _error = 'Passphrase must be at least 8 characters');
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
            'This passphrase protects your Master Seed. Make sure you remember it.',
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
        ],
      ),
    );
  }
}
