import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../services/biometric_service.dart';
import '../services/seed_service.dart';
import '../services/session_service.dart';
import '../services/vault_service.dart';
import '../theme/app_sizes.dart';
import '../widgets/unlock_action_tile.dart';
import '../main.dart';

/// Which unlock action is running, so only its own tile shows progress.
enum _Busy { none, biometric, passphrase }

/// Screen presented when returning to the application to unlock the master vault.
class UnlockPage extends StatefulWidget {
  const UnlockPage({super.key});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _passController = TextEditingController();
  bool _obscure = true;
  _Busy _busy = _Busy.none;
  String? _error;
  bool _biometricEnabled = false;
  bool _biometricPrompted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareBiometric());
  }

  bool get _isBusy => _busy != _Busy.none;

  Future<void> _prepareBiometric() async {
    final enabled = await SeedService.isBiometricEnabled();
    if (!mounted) return;
    setState(() => _biometricEnabled = enabled);
    if (!enabled || _biometricPrompted) return;

    final available = await BiometricService.isAvailable();
    if (!mounted || !available) return;
    _biometricPrompted = true;
    await _unlockWithBiometrics();
  }

  Future<void> _unlockWithBiometrics() async {
    if (_isBusy) return;
    setState(() {
      _busy = _Busy.biometric;
      _error = null;
    });

    try {
      final confirmed = await BiometricService.authenticate(
        reason: 'Unlock CurveVault with biometrics',
      );
      if (!confirmed) {
        if (mounted) setState(() => _busy = _Busy.none);
        return;
      }

      final seed = await SeedService.getBiometricSeed();
      if (seed == null) {
        if (mounted) {
          setState(() {
            _busy = _Busy.none;
            _error = 'Biometric unlock is not set up. Use your passphrase.';
          });
        }
        return;
      }

      await _completeUnlock(seed);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = _Busy.none;
          _error = 'Biometric unlock failed';
        });
      }
    }
  }

  Future<void> _completeUnlock(Uint8List seed) async {
    // Initialize runtime in-memory session with decrypted master seed
    SessionService.setSession(seed);
    await VaultService.instance.unlock(seed);

    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const MainShell()));
  }

  Future<void> _unlock() async {
    final pass = _passController.text.trim();

    if (pass.isEmpty) {
      setState(() => _error = 'Please enter your passphrase');
      return;
    }

    if (_isBusy) return;
    setState(() {
      _busy = _Busy.passphrase;
      _error = null;
    });

    try {
      final seed = await SeedService.getMasterSeed(pass);

      if (seed == null) {
        setState(() {
          _error = 'Wrong passphrase';
          _busy = _Busy.none;
        });
        return;
      }

      // Keep the biometric copy in sync after a passphrase unlock.
      try {
        if (await SeedService.isBiometricEnabled()) {
          await SeedService.enableBiometric(seed);
        }
      } catch (_) {
        // Biometric sync is best-effort; the passphrase still unlocks the vault.
      }

      await _completeUnlock(seed);
    } catch (e) {
      setState(() {
        _error = 'Failed to unlock';
        _busy = _Busy.none;
      });
    }
  }

  @override
  void dispose() {
    _passController.dispose();
    super.dispose();
  }

  InputDecoration _inputDecoration(
    BuildContext context,
    String label, {
    Widget? suffix,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hintColor = isDark ? Colors.white54 : Colors.black54;
    final borderColor = isDark ? Colors.white24 : Colors.black26;
    final focusedColor = isDark ? Colors.white70 : Colors.black87;

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: hintColor, fontSize: AppSizes.subtitle),
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

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: const Text('Unlock')),
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

          if (_biometricEnabled) ...[
            const SizedBox(height: 20),
            UnlockActionTile(
              leading: Icon(
                Icons.fingerprint,
                size: AppSizes.icon,
                color: primaryTextColor,
              ),
              title: 'Unlock with Biometrics',
              titleSize: AppSizes.subtitle + 1,
              loading: _busy == _Busy.biometric,
              onTap: _isBusy ? null : _unlockWithBiometrics,
            ),
            Divider(color: Theme.of(context).dividerColor),
          ],

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
          UnlockActionTile(
            title: _busy == _Busy.passphrase ? 'Unlocking...' : 'Unlock',
            titleSize: AppSizes.title,
            loading: _busy == _Busy.passphrase,
            dimWhenLoading: true,
            onTap: _isBusy ? null : _unlock,
          ),
        ],
      ),
    );
  }
}
