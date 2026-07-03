import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageService {
  static const _secureStorage = FlutterSecureStorage();
  static const _hiveSecretKeyName = 'hive_aes_encryption_key';

  // --- BOX NAMES ---
  static const String _settingsBoxName = 'settings_config';
  static const String _identityBoxName = 'identity_data';
  static const String _historyBoxName = 'chat_history';

  // --- HIVE KEYS ---
  static const _keyName = 'dec_chat_private_key';
  static const _serverIpKey = 'saved_websocket_server_ip';
  static const _peerListKey = 'saved_chat_peers_list';

  static Future<void> initDatabase() async {
    await Hive.initFlutter('morse-messenger');
    
    // Pre-open the configuration settings box on startup
    await Hive.openBox(_settingsBoxName);
  }

  static String _toBoxKey(String rawPublicKey) {
    final cleaned = rawPublicKey.replaceAll(RegExp(r'\s+'), '');
    if (cleaned.length <= 100) return cleaned;
    return cleaned.substring(cleaned.length - 100);
  }

  static Future<List<int>> _getDatabaseKey() async {
    try {
      final savedKeyString = await _secureStorage.read(key: _hiveSecretKeyName);
      if (savedKeyString != null) {
        return base64Url.decode(savedKeyString);
      } else {
        final newKey = Hive.generateSecureKey();
        await _secureStorage.write(
          key: _hiveSecretKeyName,
          value: base64Url.encode(newKey),
        );
        return newKey;
      }
    } catch (e) {
      debugPrint("OS Keyring locked. Using deterministic fallback key: $e");
      return List<int>.generate(32, (i) => (i + 57) % 256);
    }
  }

  // --- BOX ACQUISITION UTILITIES ---

  static Future<Box> _getIdentityBox() async {
    final encryptionKey = await _getDatabaseKey();
    try {
      return await Hive.openBox(_identityBoxName, encryptionCipher: HiveAesCipher(encryptionKey));
    } catch (e) {
      await Hive.deleteBoxFromDisk(_identityBoxName);
      return await Hive.openBox(_identityBoxName, encryptionCipher: HiveAesCipher(encryptionKey));
    }
  }

  static Future<Box> _getHistoryBox() async {
    final encryptionKey = await _getDatabaseKey();
    try {
      return await Hive.openBox(_historyBoxName, encryptionCipher: HiveAesCipher(encryptionKey));
    } catch (e) {
      await Hive.deleteBoxFromDisk(_historyBoxName);
      return await Hive.openBox(_historyBoxName, encryptionCipher: HiveAesCipher(encryptionKey));
    }
  }

  static Box _getSettingsBox() {
    return Hive.box(_settingsBoxName);
  }

  // --- IDENTITY CONFIGURATION PERSISTENCE ---
  static Future<String?> readPrivateKey() async {
    try {
      final box = await _getIdentityBox();
      return box.get(_keyName) as String?;
    } catch (e) {
      return null;
    }
  }

  static Future<void> savePrivateKey(String pemValue) async {
    try {
      final box = await _getIdentityBox();
      await box.put(_keyName, pemValue);
    } catch (_) {}
  }

  // --- PEER PROFILE CONTACT INDEXES ---
  static Future<void> savePeerList(List<Map<String, String>> serializedPeers) async {
    try {
      final box = await _getIdentityBox();
      await box.put(_peerListKey, jsonEncode(serializedPeers));
    } catch (e) {
      debugPrint("Failed to write contact indexes: $e");
    }
  }

  static Future<List<Map<String, String>>> fetchPeerList() async {
    try {
      final box = await _getIdentityBox();
      final String? rawJson = box.get(_peerListKey) as String?;
      if (rawJson == null) return [];

      final List<dynamic> decodedList = jsonDecode(rawJson);
      return List<Map<String, String>>.from(
        decodedList.map((item) => Map<String, String>.from(item as Map)),
      );
    } catch (e) {
      debugPrint("Failed to read contact indexes: $e");
      return [];
    }
  }

  // --- SECURE CHAT HISTORY PERSISTENCE LAYER ---
  static Future<void> persistEncryptedMessage({
    required String peerPublicKey,
    required String msgId,
    required String encryptedPayload,
    required bool isMe,
    required String timestampIso,
  }) async {
    try {
      final box = await _getHistoryBox();
      final hiveSafeKey = _toBoxKey(peerPublicKey);

      final String rawJsonString = box.get(hiveSafeKey, defaultValue: "[]");
      final List<dynamic> decodedList = jsonDecode(rawJsonString);

      List<Map<String, dynamic>> messageHistory = List<Map<String, dynamic>>.from(
        decodedList.map((item) => Map<String, dynamic>.from(item as Map)),
      );

      messageHistory.add({
        "id": msgId,
        "isMe": isMe,
        "payload": encryptedPayload,
        "timestamp": timestampIso,
        "isRead": isMe,
      });

      await box.put(hiveSafeKey, jsonEncode(messageHistory));
    } catch (e) {
      debugPrint("Database message append failure: $e");
    }
  }

  static Future<List<Map<String, dynamic>>> fetchHistory(String peerPublicKey) async {
    try {
      final box = await _getHistoryBox();
      final hiveSafeKey = _toBoxKey(peerPublicKey);

      final String rawJsonString = box.get(hiveSafeKey, defaultValue: "[]");
      final List<dynamic> decodedList = jsonDecode(rawJsonString);

      return List<Map<String, dynamic>>.from(
        decodedList.map((item) => Map<String, dynamic>.from(item as Map)),
      );
    } catch (e) {
      debugPrint("Database historical read failure: $e");
      return [];
    }
  }

  // --- SERVER IP SETTINGS PERSISTENCE (UNENCRYPTED / PERSISTENT) ---
  static Future<void> saveServerIp(String ipAddress) async {
    try {
      final box = _getSettingsBox();
      await box.put(_serverIpKey, ipAddress.trim());
    } catch (e) {
      debugPrint("Failed to write server IP address: $e");
    }
  }

  static Future<String?> fetchServerIp() async {
    try {
      final box = _getSettingsBox();
      return box.get(_serverIpKey) as String?;
    } catch (e) {
      debugPrint("Failed to read server IP address: $e");
      return null;
    }
  }

  // --- THE RESET IDENTITY FLOW ---
  static Future<void> resetIdentity() async {
    try {
      final identityBox = await _getIdentityBox();
      final historyBox = await _getHistoryBox();

      // Wipe contents of identity data and history data entirely
      await identityBox.clear();
      await historyBox.clear();

      debugPrint("Identity and history boxes cleared successfully. Server IP preserved.");
    } catch (e) {
      debugPrint("Error performing identity reset: $e");
    }
  }
}