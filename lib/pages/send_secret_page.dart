import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/transfer_session.dart';
import '../models/vault_entry.dart';
import '../services/native_storage.dart';
import '../services/transfer/transfer_sender.dart';
import '../services/transfer/transfer_service.dart';
import '../services/transfer/transfer_storage.dart';
import '../theme/app_sizes.dart';
import 'scan_qr_page.dart';

/// Prepares a locked vault file and sends it to another CurveVault identity.
class SendSecretPage extends StatefulWidget {
  const SendSecretPage({super.key, this.entry, this.sender});

  final VaultEntry? entry;
  final TransferSender? sender;

  @override
  State<SendSecretPage> createState() => _SendSecretPageState();
}

class _SendSecretPageState extends State<SendSecretPage> {
  static const Duration _defaultValidity = Duration(minutes: 5);
  static const List<int> _validityMinutes = [1, 5, 15, 30];

  final TextEditingController _recipientController = TextEditingController();
  final GlobalKey _qrKey = GlobalKey();
  TransferSender? _sender;
  Duration _validity = _defaultValidity;
  bool _busy = false;
  bool _sharing = false;
  String? _error;

  TransferService get _service => TransferService.instance;

  @override
  void initState() {
    super.initState();
    _sender = widget.sender;
  }

  @override
  void dispose() {
    _recipientController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final entry = widget.entry;
    if (entry == null || _busy) return;
    final normalized = _recipientController.text
        .replaceAll(RegExp(r'\s'), '')
        .toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
      setState(() => _error = 'Enter a 64-character hex public key');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.startSending(
        entry: entry,
        recipientPublicKeyHex: normalized,
        validity: _validity,
      );
      if (!mounted) return;
      setState(() => _sender = _service.sender);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sender = _service.sender;
        _error = _messageFor(error);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restart() async {
    await _service.cancel();
    if (!mounted) return;
    setState(() {
      _sender = null;
      _error = null;
    });
    await _start();
  }

  Future<void> _scanAnswer() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanQrPage(title: 'Scan Answer QR')),
    );
    if (raw == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.acceptAnswer(raw);
    } catch (error) {
      if (mounted) setState(() => _error = _messageFor(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareQr() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final boundary =
          _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        throw StateError('The QR code is not ready yet');
      }
      final image = await boundary.toImage(pixelRatio: 4);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) {
        throw StateError('Could not render the QR code');
      }
      final file = await TransferStorage.instance.writeQrPng(
        data.buffer.asUint8List(),
      );
      await NativeStorage.shareFile(
        sourcePath: file.path,
        mime: 'image/png',
        displayName: 'CurveVault-offer.png',
      );
      TransferStorage.instance.scheduleCleanup(file);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_messageFor(error))),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sender = _sender;
    return Scaffold(
      appBar: AppBar(title: const Text('Send Secret File')),
      body: sender == null
          ? _buildSetup()
          : AnimatedBuilder(
              animation: sender,
              builder: (context, _) => _buildActive(sender),
            ),
    );
  }

  Widget _buildSetup() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Text(
            'Send a locked vault file directly to another CurveVault identity. '
            'The file is re-encrypted for the recipient; nothing is uploaded to '
            'a server.',
            style: TextStyle(
              color: secondaryColor,
              fontSize: AppSizes.subtitle,
              height: 1.4,
            ),
          ),
        ),
        if (widget.entry != null)
          ListTile(
            leading: Icon(
              _iconFor(widget.entry!.mime),
              size: AppSizes.icon - 2,
              color: primaryColor,
            ),
            title: Text(
              widget.entry!.name,
              style: TextStyle(fontSize: AppSizes.subtitle + 1, color: primaryColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${_formatBytes(widget.entry!.size)} · ${widget.entry!.isReceived ? 'Received file' : 'Locked file'}',
              style: TextStyle(color: secondaryColor, fontSize: 13),
            ),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          child: TextField(
            controller: _recipientController,
            enabled: !_busy,
            maxLines: 2,
            style: TextStyle(
              color: primaryColor,
              fontFamily: 'monospace',
              fontSize: 13,
            ),
            decoration: InputDecoration(
              labelText: 'Recipient Public Key',
              labelStyle: TextStyle(color: secondaryColor, fontSize: 13),
              hintText: '64 hex characters',
              hintStyle: TextStyle(color: secondaryColor, fontSize: 13),
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
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
          child: Text(
            'QR VALIDITY',
            style: TextStyle(
              color: isDark ? Colors.white38 : Colors.black38,
              fontSize: 12,
              letterSpacing: 1,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final minutes in _validityMinutes)
                ChoiceChip(
                  label: Text('$minutes min'),
                  selected: _validity.inMinutes == minutes,
                  labelStyle: TextStyle(
                    color: _validity.inMinutes == minutes
                        ? (isDark ? Colors.black : Colors.white)
                        : primaryColor,
                    fontSize: 13,
                  ),
                  selectedColor: primaryColor,
                  backgroundColor: Colors.transparent,
                  side: BorderSide(
                    color: isDark ? Colors.white24 : Colors.black26,
                  ),
                  onSelected: _busy
                      ? null
                      : (_) => setState(
                          () => _validity = Duration(minutes: minutes),
                        ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Text(
            'The QR can only be used to establish the connection. Sending the '
            'file itself is not time-limited.',
            style: TextStyle(color: secondaryColor, fontSize: 12, height: 1.35),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text(
              _error!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        if (widget.entry != null)
          ListTile(
            enabled: !_busy,
            leading: _busy
                ? const SizedBox(
                    width: AppSizes.icon - 2,
                    height: AppSizes.icon - 2,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.qr_code_2, size: AppSizes.icon, color: primaryColor),
            title: Text(
              _busy ? 'Preparing…' : 'Create Session',
              style: TextStyle(fontSize: AppSizes.title, color: primaryColor),
            ),
            subtitle: Text(
              'Generate the QR code to send to your friend',
              style: TextStyle(color: secondaryColor, fontSize: AppSizes.subtitle),
            ),
            trailing: Icon(Icons.arrow_forward, color: primaryColor),
            onTap: _busy ? null : _start,
          ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildActive(TransferSender sender) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;

    switch (sender.phase) {
      case TransferPhase.preparing:
        return const Center(child: CircularProgressIndicator());
      case TransferPhase.waitingAnswer:
        return ListView(
          children: [
            _StageHeader(
              title: 'Send this QR to your friend',
              subtitle:
                  'Ask them to open CurveVault → Receive Secret File, then scan '
                  'this code or choose a screenshot of it.',
              primaryColor: primaryColor,
              secondaryColor: secondaryColor,
            ),
            const SizedBox(height: 8),
            Center(
              child: RepaintBoundary(
                key: _qrKey,
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(16),
                  child: QrImageView(
                    data: sender.qrPayload!,
                    version: QrVersions.auto,
                    size: 250,
                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _sharing ? null : _shareQr,
                      icon: _sharing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.ios_share),
                      label: const Text('Share QR'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _scanAnswer,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Scan Answer'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Valid for ${_remainingLabel(sender.expiresAt)}. '
                'After your friend sends the answer QR back, scan it here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: secondaryColor,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            const SizedBox(height: 24),
          ],
        );
      case TransferPhase.connecting:
        return _BusyStage(
          title: 'Connecting…',
          subtitle: 'Verifying both identities before any file data is sent.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
        );
      case TransferPhase.transferring:
        return _ProgressStage(
          title: 'Sending ${sender.fileName}',
          progress: sender.totalBytes > 0
              ? sender.sentBytes / sender.totalBytes
              : null,
          detail:
              '${_formatBytes(sender.sentBytes)} of ${_formatBytes(sender.totalBytes)}',
          subtitle:
              'You can switch apps while this runs. If the vault locks, tap '
              'Resume on the Vault page.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          onCancel: _service.cancel,
        );
      case TransferPhase.completed:
        return _ResultStage(
          icon: Icons.check_circle_outline,
          iconColor: primaryColor,
          title: 'File sent',
          subtitle: '${sender.fileName} was delivered and verified.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          primaryLabel: 'Done',
          onPrimary: () => Navigator.of(context).pop(),
          secondaryLabel: 'Send Another',
          onSecondary: () {
            Navigator.of(context).pop();
          },
        );
      case TransferPhase.expired:
        return _ResultStage(
          icon: Icons.timer_off_outlined,
          iconColor: Colors.orangeAccent,
          title: 'Expired',
          subtitle:
              'The QR code can no longer be used to establish a connection. '
              'Create a new session and share the new QR.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          primaryLabel: 'Create New Session',
          onPrimary: _restart,
          secondaryLabel: 'Back',
          onSecondary: () => Navigator.of(context).pop(),
        );
      case TransferPhase.failed:
        return _ResultStage(
          icon: Icons.error_outline,
          iconColor: Colors.redAccent,
          title: 'Transfer failed',
          subtitle:
              sender.errorMessage ??
              _error ??
              'The other device could not finish the transfer.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          primaryLabel: 'Try Again',
          onPrimary: () {
            setState(() => _sender = null);
          },
          secondaryLabel: 'Close',
          onSecondary: () => Navigator.of(context).pop(),
        );
      case TransferPhase.cancelled:
        return _ResultStage(
          icon: Icons.cancel_outlined,
          iconColor: secondaryColor,
          title: 'Transfer cancelled',
          subtitle: 'Nothing else was shared.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          primaryLabel: 'Back',
          onPrimary: () => Navigator.of(context).pop(),
        );
      case TransferPhase.waitingConnection:
      case TransferPhase.idle:
        return const Center(child: CircularProgressIndicator());
    }
  }

  static String _remainingLabel(int expiresAtSeconds) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final seconds = expiresAtSeconds - now;
    if (seconds <= 0) return 'less than a minute';
    final minutes = (seconds / 60).ceil();
    return '$minutes minute${minutes == 1 ? '' : 's'}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.videocam_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _messageFor(Object error) {
    if (error is TransferException) return error.message;
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}

class _StageHeader extends StatelessWidget {
  const _StageHeader({
    required this.title,
    required this.subtitle,
    required this.primaryColor,
    required this.secondaryColor,
  });

  final String title;
  final String subtitle;
  final Color primaryColor;
  final Color secondaryColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Column(
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: primaryColor,
              fontSize: AppSizes.title - 6,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: secondaryColor,
              fontSize: AppSizes.subtitle,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _BusyStage extends StatelessWidget {
  const _BusyStage({
    required this.title,
    required this.subtitle,
    required this.primaryColor,
    required this.secondaryColor,
  });

  final String title;
  final String subtitle;
  final Color primaryColor;
  final Color secondaryColor;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              title,
              style: TextStyle(
                color: primaryColor,
                fontSize: AppSizes.title - 6,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryColor,
                fontSize: AppSizes.subtitle,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressStage extends StatelessWidget {
  const _ProgressStage({
    required this.title,
    required this.progress,
    required this.detail,
    required this.subtitle,
    required this.primaryColor,
    required this.secondaryColor,
    required this.onCancel,
  });

  final String title;
  final double? progress;
  final String detail;
  final String subtitle;
  final Color primaryColor;
  final Color secondaryColor;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: primaryColor,
                fontSize: AppSizes.title - 6,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 24),
            LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: isDark ? Colors.white12 : Colors.black12,
              valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
            ),
            const SizedBox(height: 10),
            Text(
              detail,
              style: TextStyle(color: secondaryColor, fontSize: 13),
            ),
            const SizedBox(height: 18),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryColor,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => onCancel(),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultStage extends StatelessWidget {
  const _ResultStage({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.primaryColor,
    required this.secondaryColor,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Color primaryColor;
  final Color secondaryColor;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: AppSizes.icon + 30, color: iconColor),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: primaryColor,
                fontSize: AppSizes.title - 4,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: secondaryColor,
                fontSize: AppSizes.subtitle,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 26),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onPrimary,
                child: Text(primaryLabel),
              ),
            ),
            if (secondaryLabel != null && onSecondary != null)
              TextButton(
                onPressed: onSecondary,
                child: Text(
                  secondaryLabel!,
                  style: TextStyle(color: secondaryColor),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
