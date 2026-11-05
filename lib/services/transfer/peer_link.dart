import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../models/transfer_session.dart';

/// Small wrapper around a data-only WebRTC peer connection.
///
/// The offer and answer are exchanged through QR codes. Individual ICE
/// candidates are intentionally ignored: the connection waits until gathering
/// finishes so the final SDP already contains every candidate. That keeps the
/// signal compact enough for a QR code.
class PeerLink {
  PeerLink._(this._peerConnection);

  static const String ctrlLabel = 'ctrl';
  static const String dataLabel = 'data';

  static const int _bufferedHighWater = 512 * 1024;
  static const int _bufferedLowWater = 128 * 1024;

  static const Duration _gatheringTimeout = Duration(seconds: 8);
  static const Duration _channelTimeout = Duration(seconds: 45);

  final RTCPeerConnection _peerConnection;

  RTCDataChannel? _ctrl;
  RTCDataChannel? _data;
  final Completer<void> _channelsReady = Completer<void>();
  final StreamController<Map<String, dynamic>> _ctrlMessages =
      StreamController<Map<String, dynamic>>();
  final StreamController<Uint8List> _dataMessages =
      StreamController<Uint8List>();
  bool _closed = false;

  Stream<Map<String, dynamic>> get ctrlMessages => _ctrlMessages.stream;
  Stream<Uint8List> get dataMessages => _dataMessages.stream;
  bool get isClosed => _closed;

  static Future<PeerLink> sender() async {
    final link = PeerLink._(await _newPeerConnection());
    link._ctrl = await link._peerConnection.createDataChannel(
      ctrlLabel,
      RTCDataChannelInit()..ordered = true,
    );
    link._data = await link._peerConnection.createDataChannel(
      dataLabel,
      RTCDataChannelInit()..ordered = true,
    );
    link._wireChannels();
    link._watchConnection();
    return link;
  }

  static Future<PeerLink> receiver() async {
    final link = PeerLink._(await _newPeerConnection());
    link._peerConnection.onDataChannel = (channel) {
      switch (channel.label) {
        case ctrlLabel:
          link._ctrl = channel;
        case dataLabel:
          link._data = channel;
        default:
          return;
      }
      link._wireChannels();
    };
    link._watchConnection();
    return link;
  }

  static Future<RTCPeerConnection> _newPeerConnection() {
    return createPeerConnection(<String, dynamic>{
      'iceServers': <Map<String, dynamic>>[
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun.cloudflare.com:3478'},
        {
          'urls': [
            'turn:openrelay.metered.ca:80',
            'turn:openrelay.metered.ca:443',
            'turn:openrelay.metered.ca:443?transport=tcp',
          ],
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
      ],
      'sdpSemantics': 'unified-plan',
      'iceCandidatePoolSize': 10,
    });
  }

  /// Fails pending work as soon as the peer connection dies on its own.
  ///
  /// Without this a transfer that loses the other device would keep waiting
  /// forever (there is deliberately no transfer-duration timeout).
  void _watchConnection() {
    _peerConnection.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        unawaited(close());
      }
    };
  }

  void _wireChannels() {
    final ctrl = _ctrl;
    final data = _data;
    if (ctrl == null || data == null) return;
    if (_channelsReady.isCompleted) return;

    ctrl.onMessage = (message) {
      if (message.isBinary || _ctrlMessages.isClosed) return;
      try {
        final decoded = jsonDecode(message.text);
        if (decoded is Map) {
          _ctrlMessages.add(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // Ignore malformed control messages.
      }
    };

    data.onMessage = (message) {
      if (_dataMessages.isClosed) return;
      if (message.isBinary) {
        _dataMessages.add(message.binary);
      }
    };

    data.bufferedAmountLowThreshold = _bufferedLowWater;

    _channelsReady.complete();
  }

  Future<String> createOffer() async {
    final offer = await _peerConnection.createOffer();
    await _peerConnection.setLocalDescription(offer);
    return _gatherLocalSdp(offer.sdp);
  }

  Future<String> createAnswer(String offerSdp) async {
    await _peerConnection.setRemoteDescription(
      RTCSessionDescription(offerSdp, 'offer'),
    );
    final answer = await _peerConnection.createAnswer();
    await _peerConnection.setLocalDescription(answer);
    return _gatherLocalSdp(answer.sdp);
  }

  Future<void> applyAnswer(String answerSdp) async {
    await _peerConnection.setRemoteDescription(
      RTCSessionDescription(answerSdp, 'answer'),
    );
  }

  Future<String> _gatherLocalSdp(String? fallback) async {
    if (_peerConnection.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      final gathered = Completer<void>();
      _peerConnection.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !gathered.isCompleted) {
          gathered.complete();
        }
      };
      try {
        await gathered.future.timeout(_gatheringTimeout);
      } on TimeoutException {
        // Fall back to the SDP gathered so far.
      } finally {
        _peerConnection.onIceGatheringState = null;
      }
    }

    final local = await _peerConnection.getLocalDescription();
    final sdp = local?.sdp ?? fallback ?? '';
    if (sdp.isEmpty) {
      throw const TransferException('Could not build a connection offer');
    }
    return sdp;
  }

  Future<void> waitForChannels({
    Duration timeout = _channelTimeout,
  }) async {
    if (_closed) {
      throw const TransferException('The connection closed');
    }
    if (!_channelsReady.isCompleted) {
      try {
        await _channelsReady.future.timeout(timeout);
      } on TimeoutException {
        throw const TransferException('The connection timed out');
      }
    }
    if (_closed) {
      throw const TransferException('The connection closed');
    }

    final ctrl = _ctrl;
    final data = _data;
    if (ctrl == null || data == null) {
      throw const TransferException('The connection did not open');
    }
    await Future.wait([_waitOpen(ctrl, timeout), _waitOpen(data, timeout)]);
  }

  Future<void> _waitOpen(RTCDataChannel channel, Duration timeout) async {
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) return;

    final opened = Completer<void>();
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen &&
          !opened.isCompleted) {
        opened.complete();
      } else if ((state == RTCDataChannelState.RTCDataChannelClosed ||
              state == RTCDataChannelState.RTCDataChannelClosing) &&
          !opened.isCompleted) {
        opened.completeError(
          const TransferException('The connection closed before opening'),
        );
      }
    };

    try {
      await opened.future.timeout(timeout);
    } on TimeoutException {
      throw const TransferException('The connection timed out');
    }
  }

  Future<void> sendCtrl(Map<String, dynamic> message) async {
    final channel = _ctrl;
    if (channel == null) {
      throw const TransferException('The control channel is not open');
    }
    await channel.send(RTCDataChannelMessage(jsonEncode(message)));
  }

  Future<void> sendData(Uint8List bytes) async {
    final channel = _data;
    if (channel == null) {
      throw const TransferException('The data channel is not open');
    }

    while (!_closed && (channel.bufferedAmount ?? 0) > _bufferedHighWater) {
      final low = Completer<void>();
      final previous = channel.onBufferedAmountLow;
      channel.onBufferedAmountLow = (amount) {
        previous?.call(amount);
        if (!low.isCompleted) low.complete();
      };
      try {
        await low.future.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        throw const TransferException('The receiver stopped responding');
      } finally {
        channel.onBufferedAmountLow = previous;
      }
    }

    await channel.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_channelsReady.isCompleted) {
      // Complete normally so an early cancel does not leave an unobserved
      // error behind; waitForChannels checks _closed instead.
      _channelsReady.complete();
    }
    try {
      await _ctrl?.close();
    } catch (_) {
      // Already closed.
    }
    try {
      await _data?.close();
    } catch (_) {
      // Already closed.
    }
    try {
      await _peerConnection.close();
    } catch (_) {
      // Already closed.
    }
    if (!_ctrlMessages.isClosed) {
      await _ctrlMessages.close();
    }
    if (!_dataMessages.isClosed) {
      await _dataMessages.close();
    }
  }
}

/// Matches typed control messages to the code that is waiting for them.
///
/// Both peers exchange a fixed handshake sequence, so a tiny inbox is easier to
/// reason about than a stream subscription in every screen.
class CtrlInbox {
  CtrlInbox(Stream<Map<String, dynamic>> stream) {
    _subscription = stream.listen(
      _handle,
      onDone: () => failAll(const TransferException('The connection closed')),
    );
  }

  late final StreamSubscription<Map<String, dynamic>> _subscription;
  final List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];
  final List<_CtrlWaiter> _waiters = <_CtrlWaiter>[];
  bool _closed = false;

  void _handle(Map<String, dynamic> message) {
    if (_closed) return;
    final type = message['t'];
    for (var i = 0; i < _waiters.length; i++) {
      if (_waiters[i].type == type) {
        final waiter = _waiters.removeAt(i);
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete(message);
        }
        return;
      }
    }
    if (_queue.length < 64) {
      _queue.add(message);
    }
  }

  Future<Map<String, dynamic>> next(String type, {Duration? timeout}) async {
    final index = _queue.indexWhere((message) => message['t'] == type);
    if (index >= 0) {
      return _queue.removeAt(index);
    }
    if (_closed) {
      throw const TransferException('The connection closed');
    }

    final completer = Completer<Map<String, dynamic>>();
    _waiters.add(_CtrlWaiter(type, completer));
    if (timeout == null) return completer.future;
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _waiters.removeWhere((waiter) => identical(waiter.completer, completer));
      throw const TransferException('The other device did not respond');
    }
  }

  void failAll(Object error) {
    if (_closed && _waiters.isEmpty) return;
    _closed = true;
    for (final waiter in _waiters) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error);
      }
    }
    _waiters.clear();
  }

  Future<void> dispose() async {
    failAll(const TransferException('The connection closed'));
    await _subscription.cancel();
  }
}

class _CtrlWaiter {
  _CtrlWaiter(this.type, this.completer);

  final String type;
  final Completer<Map<String, dynamic>> completer;
}
