import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/biometric_service.dart';
import '../services/seed_service.dart';
import '../services/session_service.dart';
import '../services/vault_service.dart';
import '../theme/app_sizes.dart';
import '../theme/theme_controller.dart';
import 'setup_page.dart';

/// Account identity and security administration screen.
class IdentityPage extends StatefulWidget {
  const IdentityPage({super.key});

  @override
  State<IdentityPage> createState() => _IdentityPageState();
}

class _IdentityPageState extends State<IdentityPage> {
  bool _copiedKey = false;
  Timer? _copyTimer;
  bool _biometricEnabled = false;
  bool _biometricAvailable = true;
  bool _biometricBusy = false;

  @override
  void initState() {
    super.initState();
    _loadBiometricState();
  }

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadBiometricState() async {
    final enabled = await SeedService.isBiometricEnabled();
    final available = await BiometricService.isAvailable();
    if (!mounted) return;
    setState(() {
      _biometricEnabled = enabled;
      _biometricAvailable = available;
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleBiometric(bool value) async {
    if (_biometricBusy) return;

    if (!value) {
      setState(() => _biometricBusy = true);
      try {
        await SeedService.disableBiometric();
        if (!mounted) return;
        setState(() => _biometricEnabled = false);
        _showSnack('Biometric unlock disabled.');
      } catch (_) {
        if (mounted) _showSnack('Could not update biometric settings.');
      } finally {
        if (mounted) setState(() => _biometricBusy = false);
      }
      return;
    }

    final seed = SessionService.masterSeed;
    if (seed == null) {
      _showSnack('Unlock the vault before enabling biometric unlock.');
      return;
    }
    if (!_biometricAvailable) {
      _showSnack('Biometric authentication is not available on this device.');
      return;
    }

    setState(() => _biometricBusy = true);
    try {
      final confirmed = await BiometricService.authenticate(
        reason: 'Confirm your identity to enable biometric unlock',
      );
      if (!confirmed) return;
      await SeedService.enableBiometric(seed);
      if (!mounted) return;
      setState(() => _biometricEnabled = true);
      _showSnack('Biometric unlock enabled.');
    } catch (_) {
      if (mounted) _showSnack('Could not update biometric settings.');
    } finally {
      if (mounted) setState(() => _biometricBusy = false);
    }
  }

  void _copyPublicKey() {
    final keyHex = SessionService.publicKeyHex;
    if (keyHex == null || keyHex.isEmpty) return;

    Clipboard.setData(ClipboardData(text: keyHex));

    _copyTimer?.cancel();
    setState(() => _copiedKey = true);
    _copyTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedKey = false);
    });
  }

  void _showQrCodeDialog() {
    final keyHex = SessionService.publicKeyHex;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: Text(
          'QR Code',
          style: TextStyle(
            fontSize: AppSizes.title - 4,
            fontWeight: FontWeight.w500,
            color: primaryColor,
          ),
        ),
        content: keyHex == null || keyHex.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'Public key not available to display QR code.',
                  style: TextStyle(
                    color: isDark ? Colors.white54 : Colors.black54,
                    fontSize: AppSizes.subtitle,
                  ),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.black : Colors.white,
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: QrImageView(
                      data: keyHex,
                      version: QrVersions.auto,
                      size: 200.0,
                      eyeStyle: QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                      dataModuleStyle: QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                      backgroundColor: isDark ? Colors.black : Colors.white,
                    ),
                  ),
                ],
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Close',
              style: TextStyle(
                color: primaryColor,
                fontSize: AppSizes.subtitle,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showChangePassphraseDialog() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? errorText;
    bool inProgress = false;
    bool success = false;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).primaryColor;
            final secondaryColor = isDark ? Colors.white54 : Colors.black54;

            InputDecoration dialogDecoration(String label) {
              return InputDecoration(
                labelText: label,
                labelStyle: TextStyle(color: secondaryColor, fontSize: 14),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(
                    color: isDark ? Colors.white24 : Colors.black26,
                  ),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: primaryColor),
                ),
              );
            }

            return AlertDialog(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              title: Text(
                'Change Passphrase',
                style: TextStyle(
                  fontSize: AppSizes.title - 4,
                  fontWeight: FontWeight.w500,
                  color: primaryColor,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (success) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Passphrase changed successfully.',
                        style: TextStyle(
                          color: isDark ? Colors.white : Colors.black,
                          fontSize: AppSizes.subtitle,
                        ),
                      ),
                    ] else ...[
                      TextField(
                        controller: currentCtrl,
                        obscureText: true,
                        style: TextStyle(color: primaryColor),
                        decoration: dialogDecoration('Current Passphrase'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: newCtrl,
                        obscureText: true,
                        style: TextStyle(color: primaryColor),
                        decoration: dialogDecoration('New Passphrase'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: confirmCtrl,
                        obscureText: true,
                        style: TextStyle(color: primaryColor),
                        decoration: dialogDecoration('Confirm New Passphrase'),
                      ),
                      if (errorText != null) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            errorText!,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: inProgress ? null : () => Navigator.of(ctx).pop(),
                  child: Text(
                    success ? 'Done' : 'Cancel',
                    style: TextStyle(color: secondaryColor),
                  ),
                ),
                if (!success)
                  TextButton(
                    onPressed: inProgress
                        ? null
                        : () async {
                            final current = currentCtrl.text.trim();
                            final newPass = newCtrl.text.trim();
                            final confirm = confirmCtrl.text.trim();

                            if (newPass.length < 8) {
                              setDialogState(() {
                                errorText =
                                    'New passphrase must be at least 8 characters';
                              });
                              return;
                            }
                            if (newPass != confirm) {
                              setDialogState(() {
                                errorText = 'New passphrases do not match';
                              });
                              return;
                            }

                            setDialogState(() {
                              inProgress = true;
                              errorText = null;
                            });

                            final ok = await SeedService.changePassphrase(
                              currentPassphrase: current,
                              newPassphrase: newPass,
                            );

                            if (ok) {
                              setDialogState(() {
                                inProgress = false;
                                success = true;
                              });
                            } else {
                              setDialogState(() {
                                inProgress = false;
                                errorText = 'Incorrect current passphrase';
                              });
                            }
                          },
                    child: inProgress
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text('Save', style: TextStyle(color: primaryColor)),
                  ),
              ],
            );
          },
        );
      },
    );

    currentCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();
  }

  Future<void> _showExportSeedDialog() async {
    final passCtrl = TextEditingController();
    String? errorText;
    String? exportedHex;
    bool inProgress = false;
    bool seedCopied = false;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).primaryColor;
            final secondaryColor = isDark ? Colors.white54 : Colors.black54;

            return AlertDialog(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              title: Text(
                'Export Master Seed',
                style: TextStyle(
                  fontSize: AppSizes.title - 4,
                  fontWeight: FontWeight.w500,
                  color: primaryColor,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (exportedHex == null) ...[
                      Text(
                        'Confirm your passphrase to reveal your 32-byte master seed.',
                        style: TextStyle(
                          color: secondaryColor,
                          fontSize: AppSizes.subtitle,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: passCtrl,
                        obscureText: true,
                        style: TextStyle(color: primaryColor),
                        decoration: InputDecoration(
                          labelText: 'Passphrase',
                          labelStyle: TextStyle(
                            color: secondaryColor,
                            fontSize: 14,
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
                      if (errorText != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          errorText!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ] else ...[
                      Text(
                        'Keep this master seed strictly confidential:',
                        style: TextStyle(
                          color: secondaryColor,
                          fontSize: AppSizes.subtitle,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        child: SelectableText(
                          exportedHex!,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            color: isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (seedCopied)
                        Text(
                          'Copied to clipboard',
                          style: TextStyle(
                            color: primaryColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
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
                    exportedHex == null ? 'Cancel' : 'Close',
                    style: TextStyle(color: secondaryColor),
                  ),
                ),
                if (exportedHex == null)
                  TextButton(
                    onPressed: inProgress
                        ? null
                        : () async {
                            final pass = passCtrl.text.trim();
                            if (pass.isEmpty) {
                              setDialogState(
                                () =>
                                    errorText = 'Please enter your passphrase',
                              );
                              return;
                            }

                            setDialogState(() {
                              inProgress = true;
                              errorText = null;
                            });

                            final seed = await SeedService.getMasterSeed(pass);
                            if (seed != null) {
                              final hex = seed
                                  .map(
                                    (b) => b.toRadixString(16).padLeft(2, '0'),
                                  )
                                  .join();
                              setDialogState(() {
                                inProgress = false;
                                exportedHex = hex;
                              });
                            } else {
                              setDialogState(() {
                                inProgress = false;
                                errorText = 'Incorrect passphrase';
                              });
                            }
                          },
                    child: inProgress
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text('Reveal', style: TextStyle(color: primaryColor)),
                  )
                else
                  TextButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: exportedHex!));
                      setDialogState(() => seedCopied = true);
                    },
                    child: Text(
                      'Copy Seed',
                      style: TextStyle(color: primaryColor),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );

    passCtrl.dispose();
  }

  Future<void> _showWipeConfirmationDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: const Text(
          'Wipe All Data?',
          style: TextStyle(
            color: Colors.redAccent,
            fontWeight: FontWeight.w500,
          ),
        ),
        content: Text(
          'This will permanently erase all master seeds, identity keys, the vault index, and configurations from this device. Every locked .cvlt file will become unreadable forever. This operation cannot be reversed.',
          style: TextStyle(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white70
                : Colors.black87,
            fontSize: AppSizes.subtitle,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white54
                    : Colors.black54,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Wipe Everything',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await VaultService.instance.lockAndClear();
      await SeedService.wipe();
      SessionService.clearSession();

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SetupPage()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryTextColor = isDark ? Colors.white38 : Colors.black38;
    final keyHex = SessionService.publicKeyHex;

    return Scaffold(
      appBar: AppBar(title: const Text('Identity')),
      body: ListView(
        children: [
          ListTile(
            title: Text(
              'Public Key',
              style: TextStyle(fontSize: AppSizes.title, color: primaryColor),
            ),
            subtitle: Text(
              _copiedKey
                  ? 'Copied to clipboard'
                  : (keyHex ?? 'Not generated yet'),
              style: TextStyle(
                color: _copiedKey ? primaryColor : secondaryTextColor,
                fontFamily: 'monospace',
                fontSize: AppSizes.subtitle,
                fontWeight: _copiedKey ? FontWeight.w500 : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _copiedKey
                ? Icon(Icons.check, size: AppSizes.icon, color: primaryColor)
                : null,
            onTap: _copyPublicKey,
          ),
          const Divider(height: 1),

          ListTile(
            leading: Icon(
              Icons.qr_code,
              size: AppSizes.icon,
              color: primaryColor,
            ),
            title: Text(
              'Show QR Code',
              style: TextStyle(fontSize: AppSizes.title, color: primaryColor),
            ),
            onTap: _showQrCodeDialog,
          ),
          ListTile(
            leading: Icon(
              _copiedKey ? Icons.check : Icons.copy,
              size: AppSizes.icon,
              color: primaryColor,
            ),
            title: Text(
              _copiedKey ? 'Copied' : 'Copy Public Key',
              style: TextStyle(fontSize: AppSizes.title, color: primaryColor),
            ),
            onTap: _copyPublicKey,
          ),

          const SizedBox(height: AppSizes.sectionSpacing),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
            child: Text(
              'SECURITY',
              style: TextStyle(
                color: secondaryTextColor,
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
          ),

          ListTile(
            leading: Icon(
              Icons.password,
              size: AppSizes.icon,
              color: primaryColor,
            ),
            title: Text(
              'Change Passphrase',
              style: TextStyle(fontSize: AppSizes.title, color: primaryColor),
            ),
            onTap: _showChangePassphraseDialog,
          ),
          ListTile(
            leading: Icon(
              Icons.fingerprint,
              size: AppSizes.icon,
              color: primaryColor,
            ),
            title: Text(
              'Biometric Unlock',
              style: TextStyle(fontSize: AppSizes.title, color: primaryColor),
            ),
            subtitle: Text(
              _biometricEnabled
                  ? 'Unlock with your fingerprint or face'
                  : _biometricAvailable
                  ? 'Use your fingerprint or face to unlock'
                  : 'Not available on this device',
              style: TextStyle(color: secondaryTextColor, fontSize: 12),
            ),
            trailing: _biometricBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Switch(
                    value: _biometricEnabled,
                    onChanged: _toggleBiometric,
                    activeThumbColor: isDark ? Colors.white : Colors.black,
                    activeTrackColor: isDark ? Colors.white38 : Colors.black26,
                    inactiveThumbColor: isDark
                        ? Colors.white54
                        : Colors.grey[400],
                    inactiveTrackColor: isDark
                        ? Colors.white24
                        : Colors.grey[300],
                  ),
            onTap: _biometricBusy
                ? null
                : () => _toggleBiometric(!_biometricEnabled),
          ),
          ListTile(
            leading: Icon(
              Icons.download,
              size: AppSizes.icon,
              color: primaryColor,
            ),
            title: Text(
              'Export Seed',
              style: TextStyle(fontSize: AppSizes.title, color: primaryColor),
            ),
            onTap: _showExportSeedDialog,
          ),

          // Classic Material 2 Theme Toggle positioned directly below Export Seed
          ListTile(
            leading: Icon(
              isDark ? Icons.dark_mode : Icons.dark_mode_outlined,
              size: AppSizes.icon,
              color: primaryColor,
            ),
            title: Text(
              'Dark Theme',
              style: TextStyle(fontSize: AppSizes.title, color: primaryColor),
            ),
            trailing: Switch(
              value: isDark,
              onChanged: (val) {
                ThemeController.instance.toggleTheme(val);
              },
              activeThumbColor: isDark ? Colors.white : Colors.black,
              activeTrackColor: isDark ? Colors.white38 : Colors.black26,
              inactiveThumbColor: isDark ? Colors.white54 : Colors.grey[400],
              inactiveTrackColor: isDark ? Colors.white24 : Colors.grey[300],
            ),
            onTap: () {
              ThemeController.instance.toggleTheme(!isDark);
            },
          ),

          const SizedBox(height: AppSizes.sectionSpacing),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
            child: Text(
              'DANGER ZONE',
              style: TextStyle(
                color: secondaryTextColor,
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
          ),

          ListTile(
            leading: Icon(
              Icons.delete_forever,
              size: AppSizes.icon,
              color: Colors.redAccent,
            ),
            title: Text(
              'Wipe All Data',
              style: TextStyle(
                color: Colors.redAccent,
                fontSize: AppSizes.title,
              ),
            ),
            onTap: _showWipeConfirmationDialog,
          ),

          const SizedBox(height: AppSizes.sectionSpacing),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isDark ? Colors.white12 : Colors.black12,
            ),
            child: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final info = snapshot.data;
                final version = info == null
                    ? '...'
                    : '${info.version} (build ${info.buildNumber})';
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'VERSION',
                      style: TextStyle(
                        color: secondaryTextColor,
                        fontSize: 12,
                        letterSpacing: 1,
                      ),
                    ),
                    Text(
                      version,
                      style: TextStyle(
                        color: primaryColor,
                        fontSize: AppSizes.subtitle,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
