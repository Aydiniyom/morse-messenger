import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:crypton/crypton.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'models.dart';
import 'storage_service.dart';

class ChatSessionManager {
  final String serverIp;
  final String myRawPublicKey;
  final RSAPrivateKey privKey;
  
  IOWebSocketChannel? channel;
  bool isServerConnected = false;
  bool isConnecting = false;

  final VoidCallback onStateChanged;
  final Function(String senderKey) onFriendRequestReceived;
  final Function(String senderKey, String text, Map<String, dynamic> payload) onMessageReceived;
  final Function(String senderKey, String msgId) onReadReceiptReceived;
  final Function(String senderKey) onFriendRequestAccepted;
  final Function(Set<String> onlinePeers) onStatusUpdateReceived;

  final Set<String> _onlinePeers = {};
  Set<String> get onlinePeers => _onlinePeers;

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
  });

  void initializeWebSocket() async {
    if (isConnecting) return;
    
    // Clean close any trailing pipes explicitly
    await channel?.sink.close();
    
    isConnecting = true;
    isServerConnected = false;
    onStateChanged();

    try {
      final wsUrl = serverIp.startsWith("ws://") || serverIp.startsWith("wss://")
          ? serverIp
          : serverIp.endsWith('/ws')
              ? "ws://$serverIp"
              : "ws://$serverIp/ws";

      // FIXED: Use IOWebSocketChannel.connect to expose the native pingInterval configuration
      final connectedChannel = IOWebSocketChannel.connect(
        Uri.parse(wsUrl),
        pingInterval: const Duration(seconds: 20),
      );
      
      channel = connectedChannel;
      await connectedChannel.ready;

      isServerConnected = true;
      isConnecting = false;
      onStateChanged();

      StorageService.saveServerIp(serverIp);

      channel!.sink.add(
        jsonEncode({
          "type": "register",
          "fromUser": myRawPublicKey,
          "toUser": "",
          "payload": "",
        }),
      );

      channel!.stream.listen(
        (rawData) => _handleIncomingPacket(rawData.toString()),
        onError: (err) {
          debugPrint("WebSocket stream encountered an error pipeline condition: $err");
          _handleDisconnect();
        },
        onDone: () {
          _handleDisconnect();
        },
      );
    } catch (e) {
      debugPrint("WebSocket initialization failed: $e");
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    if (!isServerConnected && !isConnecting) return;
    isServerConnected = false;
    isConnecting = false;
    onStateChanged();
  }

  void disconnect() {
    channel?.sink.close();
    _handleDisconnect();
  }

  void _handleIncomingPacket(String rawData) {
    Map<String, dynamic>? parsedPayloadMap;
    String senderPublicKey = '';

    try {
      final data = jsonDecode(rawData);
      senderPublicKey = data['fromUser'].toString().trim();
      final String rawPayload = data['payload'].toString();
      final String packetType = data['type'] ?? '';

      if (packetType == 'status_update') {
        if (senderPublicKey == 'server') {
          _onlinePeers.clear(); // Flush historical data tracking states
          final List<dynamic> currentOnlineList = jsonDecode(data['payload']);
          _onlinePeers.addAll(currentOnlineList.map((e) => e.toString().trim()));
        } else {
          final String status = data['payload'];
          if (status == 'online') {
            _onlinePeers.add(senderPublicKey);
          } else {
            _onlinePeers.remove(senderPublicKey);
          }
        }
        onStatusUpdateReceived(_onlinePeers);
        return;
      }

      String decryptedPayloadString;
      bool isHybridPacket = false;

      try {
        decryptedPayloadString = privKey.decrypt(rawPayload);
        parsedPayloadMap = jsonDecode(decryptedPayloadString);
      } catch (_) {
        isHybridPacket = true;
      }

      if (isHybridPacket) {
        final Map<String, dynamic> hybridBundle = jsonDecode(rawPayload);
        final String rsaEncryptedKeyBundle = hybridBundle['encryptedAesKey'];
        final String base64Ciphertext = hybridBundle['ciphertext'];

        final decryptedKeyBundleString = privKey.decrypt(rsaEncryptedKeyBundle);
        final Map<String, dynamic> keyBundleMap = jsonDecode(decryptedKeyBundleString);

        final aesKey = enc.Key.fromBase64(keyBundleMap['key']);
        final iv = enc.IV.fromBase64(keyBundleMap['iv']);

        final encrypter = enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.cbc));
        final decryptedMessageTextPayload = encrypter.decrypt64(base64Ciphertext, iv: iv);

        parsedPayloadMap = jsonDecode(decryptedMessageTextPayload);
      }
    } catch (decryptionError) {
      debugPrint("Actual decryption/parsing failed: $decryptionError");
      return;
    }

    if (parsedPayloadMap == null) return;

    if (parsedPayloadMap['isReceipt'] == true) {
      onReadReceiptReceived(senderPublicKey, parsedPayloadMap['msgId']);
      return;
    }

    if (parsedPayloadMap['isFriendRequest'] == true) {
      onFriendRequestReceived(senderPublicKey);
      return;
    }

    if (parsedPayloadMap['didAcceptFRequest'] == true) {
      onFriendRequestAccepted(senderPublicKey);
      return;
    }

    onMessageReceived(
      senderPublicKey,
      parsedPayloadMap['text'] ?? '',
      parsedPayloadMap,
    );
  }

  void sendReadReceipt(String targetKey, String messageId) {
    if (channel == null || !isServerConnected) return;
    try {
      final recipientPublicKeyObj = RSAPublicKey.fromString(targetKey.trim());
      final receiptPayload = jsonEncode({"isReceipt": true, "msgId": messageId});

      channel!.sink.add(
        jsonEncode({
          "type": "message",
          "fromUser": myRawPublicKey,
          "toUser": targetKey.trim(),
          "payload": recipientPublicKeyObj.encrypt(receiptPayload),
        }),
      );
    } catch (e) {
      debugPrint("Failed to serialize read receipt structural packet payload: $e");
    }
  }

  void sendFriendRequest(String targetKey) {
    if (channel == null || !isServerConnected) return;
    try {
      final recipientPublicKeyObj = RSAPublicKey.fromString(targetKey.trim());
      final requestPayload = jsonEncode({"isFriendRequest": true});

      channel!.sink.add(
        jsonEncode({
          "type": "message",
          "fromUser": myRawPublicKey,
          "toUser": targetKey.trim(),
          "payload": recipientPublicKeyObj.encrypt(requestPayload),
        }),
      );
    } catch (e) {
      debugPrint("Failed to encrypt structural friend request packet payload: $e");
    }
  }

  void sendFriendRequestReaction(String targetKey, bool didAccept) {
    if (channel == null || !isServerConnected) return;
    try {
      final recipientPublicKeyObj = RSAPublicKey.fromString(targetKey.trim());
      final requestPayload = jsonEncode({"didAcceptFRequest": didAccept});

      channel!.sink.add(
        jsonEncode({
          "type": "message",
          "fromUser": myRawPublicKey,
          "toUser": targetKey.trim(),
          "payload": recipientPublicKeyObj.encrypt(requestPayload),
        }),
      );
    } catch (e) {
      debugPrint("Failed to execute friend selection transmission sequence: $e");
    }
  }

  Future<void> sendChatMessage({
    required String targetKey,
    required String text,
    required String msgId,
    required DateTime timestamp,
  }) async {
    if (channel == null || !isServerConnected) throw Exception("Network channel unavailable");

    final recipientPublicKeyObj = RSAPublicKey.fromString(targetKey.trim());

    final innerMessagePayload = jsonEncode({
      "isReceipt": false,
      "isFriendRequest": false,
      "text": text,
      "msgId": msgId,
      "timestamp": timestamp.toIso8601String(),
    });

    final ephemeralAesKey = enc.Key.fromSecureRandom(32);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(ephemeralAesKey, mode: enc.AESMode.cbc));
    final encryptedCiphertext = encrypter.encrypt(innerMessagePayload, iv: iv);

    final keyBundleToEncrypt = jsonEncode({
      "key": ephemeralAesKey.base64,
      "iv": iv.base64,
    });
    final rsaEncryptedKeyBundle = recipientPublicKeyObj.encrypt(keyBundleToEncrypt);

    final structuralNetworkPacket = jsonEncode({
      "encryptedAesKey": rsaEncryptedKeyBundle,
      "ciphertext": encryptedCiphertext.base64,
    });

    channel!.sink.add(
      jsonEncode({
        "type": "message",
        "fromUser": myRawPublicKey,
        "toUser": targetKey.trim(),
        "payload": structuralNetworkPacket,
      }),
    );
  }

  Future<void> sendMediaMessage({
    required String targetKey,
    required String msgId,
    required DateTime timestamp,
    required String text,
    required String mediaType,
    required String fileName,
    required String base64Payload,
  }) async {
    if (channel == null || !isServerConnected) throw Exception("Network channel unavailable");

    final recipientPublicKeyObj = RSAPublicKey.fromString(targetKey.trim());

    final rawInnerPayloadJson = jsonEncode({
      "text": text,
      "msgId": msgId,
      "timestamp": timestamp.toIso8601String(),
      "mediaType": mediaType,
      "mediaFileName": fileName,
      "base64Data": base64Payload,
    });

    final ephemeralAesKey = enc.Key.fromSecureRandom(32);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(ephemeralAesKey, mode: enc.AESMode.cbc));
    final encryptedCiphertext = encrypter.encrypt(rawInnerPayloadJson, iv: iv);

    final keyBundleToEncrypt = jsonEncode({
      "key": ephemeralAesKey.base64,
      "iv": iv.base64,
    });
    final rsaEncryptedKeyBundle = recipientPublicKeyObj.encrypt(keyBundleToEncrypt);

    channel!.sink.add(
      jsonEncode({
        "type": "message",
        "fromUser": myRawPublicKey,
        "toUser": targetKey.trim(),
        "payload": jsonEncode({
          "encryptedAesKey": rsaEncryptedKeyBundle,
          "ciphertext": encryptedCiphertext.base64,
        }),
      }),
    );
  }
}