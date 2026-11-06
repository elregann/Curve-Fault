import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/transfer_session.dart';
import '../services/native_storage.dart';
import '../services/transfer/transfer_receiver.dart';
import '../services/transfer/transfer_service.dart';
import '../services/transfer/transfer_storage.dart';
import '../theme/app_sizes.dart';
import 'scan_qr_page.dart';

/// Receives a secret file from another CurveVault identity.
class ReceiveSecretPage extends StatefulWidget {
  const ReceiveSecretPage({super.key, this.receiver});

  final TransferReceiver? receiver;

  @override
  State<ReceiveSecretPage> createState() => _ReceiveSecretPageState();
}

class _ReceiveSecretPageState extends State<ReceiveSecretPage> {
  final GlobalKey _qrKey = GlobalKey();
  TransferReceiver? _receiver;
  bool _busy = false;
  bool _sharing = false;
  String? _error;

  TransferService get _service => TransferService.instance;

  @override
  void initState() {
    super.initState();
    _receiver = widget.receiver;
  }

  Future<void> _scanOffer() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanQrPage(title: 'Scan Offer QR')),
    );
    if (raw == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.startReceiving(offerQr: raw);
      if (!mounted) return;
      setState(() => _receiver = _service.receiver);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _receiver = _service.receiver;
        _error = _messageFor(error);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanAgain() async {
    await _service.cancel();
    if (!mounted) return;
    setState(() {
      _receiver = null;
      _error = null;
    });
    await _scanOffer();
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
        displayName: 'CurveVault-answer.png',
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
    final receiver = _receiver;
    return Scaffold(
      appBar: AppBar(title: const Text('Receive Secret File')),
      body: receiver == null
          ? _buildSetup()
          : AnimatedBuilder(
              animation: receiver,
              builder: (context, _) => _buildActive(receiver),
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
            'Scan the QR code your friend sent you. CurveVault checks the '
            'sender identity and the file signature before adding it to your '
            'vault.',
            style: TextStyle(
              color: secondaryColor,
              fontSize: AppSizes.subtitle,
              height: 1.4,
            ),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          enabled: !_busy,
          leading: _busy
              ? const SizedBox(
                  width: AppSizes.icon - 2,
                  height: AppSizes.icon - 2,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.qr_code_scanner, size: AppSizes.icon, color: primaryColor),
          title: Text(
            _busy ? 'Reading the offer…' : 'Scan Offer QR',
            style: TextStyle(fontSize: AppSizes.title, color: primaryColor),
          ),
          subtitle: Text(
            'Use the camera, or choose a QR screenshot from the gallery',
            style: TextStyle(color: secondaryColor, fontSize: AppSizes.subtitle),
          ),
          trailing: Icon(Icons.arrow_forward, color: primaryColor),
          onTap: _busy ? null : _scanOffer,
        ),
        const Divider(height: 1),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
          child: Text(
            'The QR is only a connection handshake. It expires after a few '
            'minutes; ask your friend for a new one if that happens.',
            style: TextStyle(color: secondaryColor, fontSize: 12, height: 1.35),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildActive(TransferReceiver receiver) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;

    switch (receiver.phase) {
      case TransferPhase.preparing:
        return const Center(child: CircularProgressIndicator());
      case TransferPhase.waitingConnection:
        return ListView(
          children: [
            _Header(
              title: 'Send this answer QR back',
              subtitle:
                  'Your friend needs to scan this code to connect. You can also '
                  'share it through WhatsApp.',
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
                    data: receiver.qrPayload!,
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
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _sharing ? null : _shareQr,
                  icon: _sharing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share),
                  label: const Text('Share Answer QR'),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Waiting for the sender to connect'
                '${receiver.senderPublicKeyHex == null ? '' : ' · ${_shortKey(receiver.senderPublicKeyHex!)}'}'
                '\nValid for ${_remainingLabel(receiver.expiresAt)}.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: secondaryColor,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
            if (!receiver.relayAvailable)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  'No TURN relay was found. This is fine on the same Wi-Fi, but '
                  'a sender on another network may not be able to connect. For '
                  'remote transfers, use a build configured with a TURN server.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 12,
                    height: 1.35,
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
        return _Busy(
          title: 'Connecting…',
          subtitle: 'Verifying the sender signature and the file manifest.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
        );
      case TransferPhase.transferring:
        return _Progress(
          title: 'Receiving ${receiver.fileName ?? 'file'}',
          progress: receiver.totalBytes > 0
              ? receiver.receivedBytes / receiver.totalBytes
              : null,
          detail:
              '${_formatBytes(receiver.receivedBytes)} of ${_formatBytes(receiver.totalBytes)}',
          subtitle:
              'The file is checked against its signed manifest before it is '
              'added to the vault.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          onCancel: _service.cancel,
        );
      case TransferPhase.completed:
        return _Result(
          icon: Icons.check_circle_outline,
          iconColor: primaryColor,
          title: 'File received',
          subtitle:
              '${receiver.fileName ?? 'The file'} is now in your vault under '
              'Received.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          primaryLabel: 'Open Vault',
          onPrimary: () => Navigator.of(context).pop(),
        );
      case TransferPhase.expired:
        return _Result(
          icon: Icons.timer_off_outlined,
          iconColor: Colors.orangeAccent,
          title: 'QR is no longer valid',
          subtitle:
          'Ask your friend for a new QR code, then scan it again. Nothing '
              'was received.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          primaryLabel: 'Scan New QR',
          onPrimary: _scanAgain,
          secondaryLabel: 'Back',
          onSecondary: () => Navigator.of(context).pop(),
        );
      case TransferPhase.failed:
        return _Result(
          icon: Icons.error_outline,
          iconColor: Colors.redAccent,
          title: 'Transfer failed',
          subtitle:
          receiver.errorMessage ??
              _error ??
              'The sender could not finish the transfer.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          primaryLabel: 'Scan New QR',
          onPrimary: _scanAgain,
          secondaryLabel: 'Close',
          onSecondary: () => Navigator.of(context).pop(),
        );
      case TransferPhase.cancelled:
        return _Result(
          icon: Icons.cancel_outlined,
          iconColor: secondaryColor,
          title: 'Transfer cancelled',
          subtitle: 'Nothing was added to the vault.',
          primaryColor: primaryColor,
          secondaryColor: secondaryColor,
          primaryLabel: 'Back',
          onPrimary: () => Navigator.of(context).pop(),
        );
      case TransferPhase.waitingAnswer:
      case TransferPhase.idle:
        return const Center(child: CircularProgressIndicator());
    }
  }

  static String _shortKey(String hex) {
    if (hex.length <= 12) return hex;
    return '${hex.substring(0, 6)}…${hex.substring(hex.length - 6)}';
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

  static String _messageFor(Object error) {
    if (error is TransferException) return error.message;
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}

class _Header extends StatelessWidget {
  const _Header({
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

class _Busy extends StatelessWidget {
  const _Busy({
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

class _Progress extends StatelessWidget {
  const _Progress({
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

class _Result extends StatelessWidget {
  const _Result({
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
