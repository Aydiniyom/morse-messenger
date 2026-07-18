import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:crypton/crypton.dart';

import 'crypto_service.dart';
import 'media_service.dart';
import 'packet.dart';
import 'storage_service.dart';

/// Owns the WebSocket connection to the relay server and all message
/// send/receive plumbing.
///
/// Responsibilities:
///  - connection lifecycle (connect / reconnect / disconnect)
///  - wire-format (de)serialization via [Packet]
///  - delegating all actual cryptography to [CryptoService]
///  - routing verified, decrypted payloads to the callbacks the UI layer
///    supplied
class ChatSessionManager {
  final String serverIp;
  final String myRawPublicKey;
  final RSAPrivateKey privKey;

  final VoidCallback onStateChanged;
  final void Function(String senderKey) onFriendRequestReceived;
  final void Function(
    String senderKey,
    String text,
    Map<String, dynamic> payload,
  )
  onMessageReceived;
  final void Function(String senderKey, String msgId) onReadReceiptReceived;
  final void Function(String senderKey) onFriendRequestAccepted;
  final void Function(Set<String> onlinePeers) onStatusUpdateReceived;
  final void Function(String senderKey, String msgId) onMessageDeleted;

  ChatSessionManager({
    required this.serverIp,
    required this.myRawPublicKey,
    required this.privKey,
    required this.onStateChanged,
    required this.onFriendRequestReceived,
    required this.onMessageReceived,
    required this.onReadReceiptReceived,
    required this.onFriendRequestAccepted,
    required this.onStatusUpdateReceived,
    required this.onMessageDeleted,
  });

  // --- connection state -----------------------------------------------
  IOWebSocketChannel? _channel;
  bool isServerConnected = false;
  bool isConnecting = false;

  /// True once the caller has explicitly asked us to disconnect (app
  /// backgrounded, user changed server, widget disposed). While true, we
  /// never attempt to auto-reconnect; only an explicit
  /// [initializeWebSocket] call resumes activity.
  bool _manualDisconnect = false;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectDelaySeconds = 30;
  static const Duration _connectTimeout = Duration(seconds: 10);

  final Set<String> _onlinePeers = {};
  Set<String> get onlinePeers => _onlinePeers;

  // --- connection lifecycle ---------------------------------------------

  void initializeWebSocket() async {
    if (isConnecting) return;

    _manualDisconnect = false;
    _reconnectTimer?.cancel();

    // Close out any previous socket cleanly before opening a new one.
    await _channel?.sink.close();
    _channel = null;

    isConnecting = true;
    isServerConnected = false;
    onStateChanged();

    try {
      final wsUrl = _resolveWebSocketUrl(serverIp);

      final connectedChannel = IOWebSocketChannel.connect(
        Uri.parse(wsUrl),
        pingInterval: const Duration(seconds: 20),
      );

      // Guard against a server address that accepts the TCP connection but
      // never completes the WebSocket handshake (e.g. wrong port behind a
      // firewall); without this the app could hang in "connecting" state
      // forever.
      await connectedChannel.ready.timeout(_connectTimeout);

      _channel = connectedChannel;
      isServerConnected = true;
      isConnecting = false;
      _reconnectAttempts = 0;
      onStateChanged();

      StorageService.saveServerIp(serverIp);

      _send(
        Packet(
          type: PacketType.register,
          fromUser: myRawPublicKey,
          toUser: '',
          payload: '',
        ),
      );

      connectedChannel.stream.listen(
        (rawData) => _handleIncomingPacket(rawData.toString()),
        onError: (Object err) {
          debugPrint('WebSocket stream error: $err');
          _handleDisconnect(scheduleReconnect: true);
        },
        onDone: () {
          _handleDisconnect(scheduleReconnect: true);
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('WebSocket initialization failed: $e');
      _handleDisconnect(scheduleReconnect: true);
    }
  }

  /// Resolves a user-entered address ("host:port", "ws://host:port", ...)
  /// into a normalized WebSocket URL
  static String _resolveWebSocketUrl(String rawAddress) {
    if (rawAddress.startsWith('ws://') || rawAddress.startsWith('wss://')) {
      return rawAddress;
    }
    return rawAddress.endsWith('/ws')
        ? 'ws://$rawAddress'
        : 'ws://$rawAddress/ws';
  }

  void _handleDisconnect({bool scheduleReconnect = false}) {
    final wasConnected = isServerConnected || isConnecting;
    isServerConnected = false;
    isConnecting = false;

    if (wasConnected) {
      onStateChanged();
    }

    if (scheduleReconnect && !_manualDisconnect) {
      _scheduleReconnect();
    }
  }

  /// Schedules a reconnect attempt with capped exponential backoff plus
  /// jitter, so a relay server that's briefly restarting doesn't get
  /// hammered by every client at the exact same instant.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    _reconnectAttempts++;
    final baseDelaySeconds = min(
      _maxReconnectDelaySeconds,
      pow(2, _reconnectAttempts).toInt(),
    );
    final jitterMs = Random().nextInt(1000);
    final delay = Duration(seconds: baseDelaySeconds, milliseconds: jitterMs);

    debugPrint(
      'Scheduling reconnect attempt #$_reconnectAttempts in ${delay.inSeconds}s',
    );

    _reconnectTimer = Timer(delay, () {
      if (!_manualDisconnect) {
        initializeWebSocket();
      }
    });
  }

  /// Ends the session and suppresses auto-reconnect until
  /// [initializeWebSocket] is explicitly called again.
  void disconnect() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _handleDisconnect();
  }

  /// Releases all resources. Safe to call even if never connected.
  void dispose() {
    disconnect();
  }

  // --- outgoing packets ---------------------------------------------------

  /// Sends a raw packet over the socket. Throws if there's no live
  /// connection, so callers that need "fire and forget" semantics should
  /// catch and log; callers that need the UI to know about failure (e.g.
  /// sending a chat message) can let it propagate.
  void _send(Packet packet) {
    final channel = _channel;
    if (channel == null || !isServerConnected) {
      throw StateError('Cannot send: no active connection to the relay server');
    }
    channel.sink.add(packet.encode());
  }

  void sendReadReceipt(String targetKey, String messageId) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({'isReceipt': true, 'msgId': messageId});
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send read receipt: $e');
    }
  }

  /// Tells [targetKey] that the message identified by [messageId] should be
  /// deleted on their end too. Like every other packet, this is signed and
  /// encrypted - the relay never sees which message is being removed.
  void sendDeleteNotice(String targetKey, String messageId) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({'isDelete': true, 'msgId': messageId});
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send delete notice: $e');
    }
  }

  void sendFriendRequest(String targetKey) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({'isFriendRequest': true});
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send friend request: $e');
    }
  }

  void sendFriendRequestReaction(String targetKey, bool didAccept) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({'didAcceptFRequest': didAccept});
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send friend-request reaction: $e');
    }
  }

  Future<void> sendChatMessage({
    required String targetKey,
    required String text,
    required String msgId,
    required DateTime timestamp,
  }) async {
    final recipient = RSAPublicKey.fromString(targetKey.trim());
    final plaintext = jsonEncode({
      'isReceipt': false,
      'isFriendRequest': false,
      'text': text,
      'msgId': msgId,
      'timestamp': timestamp.toIso8601String(),
    });

    final envelope = CryptoService.encryptEnvelope(
      plaintext: plaintext,
      recipientPublicKey: recipient,
      senderPrivateKey: privKey,
    );

    _send(
      Packet(
        type: PacketType.message,
        fromUser: myRawPublicKey,
        toUser: targetKey.trim(),
        payload: envelope,
      ),
    );
  }

  /// Encrypts and sends a media attachment.
  ///
  /// Unlike a plain chat message, the media bytes themselves are never
  /// embedded in the WebSocket packet. Instead:
  ///  1. The raw bytes are encrypted with a fresh, single-use AES-256-GCM
  ///     key ([CryptoService.encryptMediaBytes]).
  ///  2. The ciphertext is streamed to the relay over HTTP POST
  ///     ([MediaService.uploadEncryptedMedia]), which hands back an opaque
  ///     media ID.
  ///  3. A small metadata packet - caption text, media ID, and the AES
  ///     key/IV - is signed and RSA-encrypted exactly like a normal chat
  ///     message and sent over the WebSocket.
  ///
  /// The relay still never sees plaintext, and the AES key is still only
  /// ever readable by the intended recipient (it's protected by the same
  /// envelope signature/encryption as any other message), but the bulk
  /// bytes no longer have to be base64-inflated and shoved through the
  /// same socket carrying live presence/read-receipt traffic.
  Future<void> sendMediaMessage({
    required String targetKey,
    required String msgId,
    required DateTime timestamp,
    required String text,
    required String mediaType,
    required String fileName,
    required Uint8List rawBytes,
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.05);

    final material = await CryptoService.encryptMediaBytesInBackground(
      rawBytes,
    );

    onProgress?.call(0.35);

    final mediaId = await MediaService.uploadEncryptedMedia(
      serverIp: serverIp,
      ciphertext: material.ciphertext,
    );

    onProgress?.call(0.8);

    final plaintext = jsonEncode({
      'text': text,
      'msgId': msgId,
      'timestamp': timestamp.toIso8601String(),
      'mediaType': mediaType,
      'mediaFileName': fileName,
      'mediaId': mediaId,
      'mediaKey': material.keyBase64,
      'mediaIv': material.ivBase64,
    });

    final envelope = await CryptoService.encryptEnvelopeInBackground(
      plaintext: plaintext,
      recipientPublicKeyPem: targetKey.trim(),
      senderPrivateKeyPem: privKey.toString(),
    );

    onProgress?.call(0.9);

    _send(
      Packet(
        type: PacketType.message,
        fromUser: myRawPublicKey,
        toUser: targetKey.trim(),
        payload: envelope,
      ),
    );

    onProgress?.call(1.0);
  }

  /// Downloads and decrypts the media referenced by an already-decrypted
  /// message payload (as delivered via [onMessageReceived]). Callers
  /// should invoke this once, right after receiving a media message, or
  /// lazily if the user re-requests a download after the local cache was
  /// cleared.
  Future<Uint8List> fetchAndDecryptMedia({
    required String mediaId,
    required String mediaKeyBase64,
    required String mediaIvBase64,
  }) async {
    final ciphertext = await MediaService.downloadEncryptedMedia(
      serverIp: serverIp,
      mediaId: mediaId,
    );

    return CryptoService.decryptMediaBytesInBackground(
      ciphertext: ciphertext,
      keyBase64: mediaKeyBase64,
      ivBase64: mediaIvBase64,
    );
  }

  // --- incoming packets ----------------------------------------------------

  void _handleIncomingPacket(String rawData) {
    final Packet packet;
    try {
      packet = Packet.decode(rawData);
    } on MalformedPacketException catch (e) {
      // Untrusted input from the network; log and move on.
      debugPrint('Dropping malformed packet: $e');
      return;
    }

    switch (packet.type) {
      case PacketType.statusUpdate:
        _handleStatusUpdate(packet);
        return;
      case PacketType.message:
        _handleMessagePacket(packet);
        return;
      case PacketType.register:
        // The server never sends "register" packets back to clients; if
        // one arrives, it's either a protocol violation or a future
        // server feature we don't understand yet. Ignoring.
        return;
    }
  }

  void _handleStatusUpdate(Packet packet) {
    try {
      if (packet.fromUser == 'server') {
        final decoded = jsonDecode(packet.payload);
        if (decoded is! List) {
          debugPrint('Ignoring status_update: roster payload is not a list');
          return;
        }
        _onlinePeers
          ..clear()
          ..addAll(decoded.whereType<Object>().map((e) => e.toString().trim()));
      } else {
        final status = packet.payload;
        if (status == 'online') {
          _onlinePeers.add(packet.fromUser);
        } else {
          _onlinePeers.remove(packet.fromUser);
        }
      }
      onStatusUpdateReceived(_onlinePeers);
    } catch (e) {
      debugPrint('Failed to process status_update: $e');
    }
  }

  void _handleMessagePacket(Packet packet) {
    final String plaintext;
    try {
      final claimedSender = RSAPublicKey.fromString(packet.fromUser);
      plaintext = CryptoService.decryptEnvelope(
        rawEnvelope: packet.payload,
        myPrivateKey: privKey,
        expectedSenderPublicKey: claimedSender,
      );
    } on EnvelopeAuthException catch (e) {
      // Either it's not addressed to us, it's corrupted/tampered, or the
      // signature doesn't match the claimed sender. drop silently in either case.
      debugPrint('Dropping unverifiable packet: $e');
      return;
    } catch (e) {
      debugPrint('Dropping packet with unparseable sender identity: $e');
      return;
    }

    final Map<String, dynamic> payloadMap;
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('decrypted payload is not a JSON object');
      }
      payloadMap = decoded;
    } catch (e) {
      debugPrint('Dropping packet with malformed decrypted payload: $e');
      return;
    }

    if (payloadMap['isDelete'] == true) {
      final msgId = payloadMap['msgId'];
      if (msgId is String) {
        onMessageDeleted(packet.fromUser, msgId);
      }
      return;
    }

    if (payloadMap['isReceipt'] == true) {
      final msgId = payloadMap['msgId'];
      if (msgId is String) {
        onReadReceiptReceived(packet.fromUser, msgId);
      }
      return;
    }

    if (payloadMap['isFriendRequest'] == true) {
      onFriendRequestReceived(packet.fromUser);
      return;
    }

    if (payloadMap['didAcceptFRequest'] == true) {
      onFriendRequestAccepted(packet.fromUser);
      return;
    }

    onMessageReceived(
      packet.fromUser,
      (payloadMap['text'] as String?) ?? '',
      payloadMap,
    );
  }
}
