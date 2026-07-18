import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Thrown for storage failures that callers may want to distinguish from
/// "there's simply no data yet" (which is represented by returning
/// null/empty, not by throwing).
class StorageException implements Exception {
  final String message;
  final Object? cause;
  const StorageException(this.message, [this.cause]);

  @override
  String toString() =>
      'StorageException: $message${cause != null ? ' ($cause)' : ''}';
}

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
  static const _colorsToggle = 'saved_colors_toggle';
  static const _peerListKey = 'saved_chat_peers_list';
  static const String savedMessagesPeerKey = '__SYSTEM_SAVED_MESSAGES__';
  static const String _savedMessagesDataKey = 'persistent_saved_messages_json';

  static Future<void> initDatabase() async {
    const isTestMode = String.fromEnvironment('APP_ENV') == 'test';
    final storageDirectory = isTestMode ? 'morse-test' : 'morse-messenger';

    await Hive.initFlutter(storageDirectory);
    await Hive.openBox(_settingsBoxName);
  }

  /// Derives a fixed-length, collision-resistant Hive key from a peer's raw
  /// public key.
  static String _toBoxKey(String rawPublicKey) {
    final cleaned = rawPublicKey.replaceAll(RegExp(r'\s+'), '');
    final digestBytes = sha256.convert(utf8.encode(cleaned)).bytes;
    return base64Url.encode(digestBytes);
  }

  static Future<List<int>> _getDatabaseKey() async {
    final savedKeyString = await _secureStorage.read(key: _hiveSecretKeyName);
    if (savedKeyString != null) {
      return base64Url.decode(savedKeyString);
    }

    final newKey = Hive.generateSecureKey();
    await _secureStorage.write(
      key: _hiveSecretKeyName,
      value: base64Url.encode(newKey),
    );
    return newKey;
  }

  // --- BOX ACQUISITION UTILITIES ---

  static bool _looksLikeCorruption(Object error) {
    if (error is! HiveError) return false;
    final msg = error.message.toLowerCase();
    return msg.contains('checksum') ||
        msg.contains('corrupt') ||
        msg.contains('decrypt') ||
        msg.contains('cipher');
  }

  static Future<Box> _openEncryptedBox(String name) async {
    final encryptionKey = await _getDatabaseKey();
    try {
      return await Hive.openBox(
        name,
        encryptionCipher: HiveAesCipher(encryptionKey),
      );
    } catch (e) {
      if (!_looksLikeCorruption(e)) {
        throw StorageException('Failed to open "$name" box', e);
      }

      debugPrint('Box "$name" appears corrupted ($e) - recreating it.');
      await Hive.deleteBoxFromDisk(name);
      try {
        return await Hive.openBox(
          name,
          encryptionCipher: HiveAesCipher(encryptionKey),
        );
      } catch (e2) {
        throw StorageException(
          'Failed to recreate "$name" box after corruption',
          e2,
        );
      }
    }
  }

  static Future<Box> _getIdentityBox() => _openEncryptedBox(_identityBoxName);
  static Future<Box> _getHistoryBox() => _openEncryptedBox(_historyBoxName);

  static Box _getSettingsBox() => Hive.box(_settingsBoxName);

  // --- IDENTITY CONFIGURATION PERSISTENCE ---

  /// Returns the saved private key PEM, or null if none exists yet.
  static Future<String?> readPrivateKey() async {
    final box = await _getIdentityBox();
    return box.get(_keyName) as String?;
  }

  static Future<void> savePrivateKey(String pemValue) async {
    final box = await _getIdentityBox();
    await box.put(_keyName, pemValue);
  }

  // --- PEER PROFILE CONTACT INDEXES ---
  static Future<void> savePeerList(
    List<Map<String, String>> serializedPeers,
  ) async {
    try {
      final box = await _getIdentityBox();
      await box.put(_peerListKey, jsonEncode(serializedPeers));
    } catch (e) {
      debugPrint('Failed to write contact list: $e');
    }
  }

  static Future<List<Map<String, String>>> fetchPeerList() async {
    try {
      final box = await _getIdentityBox();
      final String? rawJson = box.get(_peerListKey) as String?;
      if (rawJson == null) return [];

      final decodedList = jsonDecode(rawJson);
      if (decodedList is! List) return [];

      return decodedList
          .whereType<Map>()
          .map((item) => Map<String, String>.from(item))
          .toList();
    } catch (e) {
      debugPrint('Failed to read contact list: $e');
      return [];
    }
  }

  // --- SECURE CHAT HISTORY PERSISTENCE LAYER ---
  //
  // Media messages carry three extra, optional fields alongside the usual
  // text payload: [mediaType], [mediaFileName], and [localPath] (the path
  // to the locally cached copy of the attachment). Every write is merged
  // with whatever record already exists for that message ID rather than
  // blindly overwriting it, so a later call that only updates (say) the
  // read state - and doesn't know or care about media - can't accidentally
  // wipe out the media metadata that a previous call stored.
  static Future<void> persistEncryptedMessage({
    required String peerPublicKey,
    required String msgId,
    required String encryptedPayload,
    required bool isMe,
    required String timestampIso,
    String? mediaType,
    String? mediaFileName,
    String? mediaId,
    String? mediaKeyBase64,
    String? mediaIvBase64,
    String? localPath,
  }) async {
    try {
      final box = await _getHistoryBox();
      final hiveSafeKey = _toBoxKey(peerPublicKey);

      final messageHistory = await _readMessageList(box, hiveSafeKey);

      final existingIndex = messageHistory.indexWhere((m) => m['id'] == msgId);
      final Map<String, dynamic> existing =
          existingIndex != -1 ? messageHistory[existingIndex] : const {};

      final record = {
        'id': msgId,
        'isMe': isMe,
        'payload': encryptedPayload,
        'timestamp': timestampIso,
        'isRead': isMe,
        'mediaType': mediaType ?? existing['mediaType'],
        'mediaFileName': mediaFileName ?? existing['mediaFileName'],
        'mediaId': mediaId ?? existing['mediaId'],
        'mediaKeyBase64': mediaKeyBase64 ?? existing['mediaKeyBase64'],
        'mediaIvBase64': mediaIvBase64 ?? existing['mediaIvBase64'],
        'localPath': localPath ?? existing['localPath'],
      };

      if (existingIndex != -1) {
        messageHistory[existingIndex] = record;
      } else {
        messageHistory.add(record);
      }

      await box.put(hiveSafeKey, jsonEncode(messageHistory));
    } catch (e) {
      debugPrint('Failed to persist message: $e');
    }
  }

  /// Removes a single message from a peer's stored history by ID. Safe to
  /// call even if the message was never persisted (no-op in that case).
  static Future<void> deleteMessage({
    required String peerPublicKey,
    required String msgId,
  }) async {
    try {
      final box = await _getHistoryBox();
      final hiveSafeKey = _toBoxKey(peerPublicKey);
      final messageHistory = await _readMessageList(box, hiveSafeKey);
      messageHistory.removeWhere((m) => m['id'] == msgId);
      await box.put(hiveSafeKey, jsonEncode(messageHistory));
    } catch (e) {
      debugPrint('Failed to delete message: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> fetchHistory(
    String peerPublicKey,
  ) async {
    try {
      final box = await _getHistoryBox();
      final hiveSafeKey = _toBoxKey(peerPublicKey);
      return await _readMessageList(box, hiveSafeKey);
    } catch (e) {
      debugPrint('Failed to read chat history: $e');
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> _readMessageList(
    Box box,
    String key,
  ) async {
    final String rawJsonString = box.get(key, defaultValue: '[]');
    final decoded = jsonDecode(rawJsonString);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  // --- SERVER IP SETTINGS PERSISTENCE (UNENCRYPTED / PERSISTENT) ---
  static Future<void> saveServerIp(String ipAddress) async {
    try {
      final box = _getSettingsBox();
      await box.put(_serverIpKey, ipAddress.trim());
    } catch (e) {
      debugPrint('Failed to write server address: $e');
    }
  }

  static Future<String?> fetchServerIp() async {
    try {
      final box = _getSettingsBox();
      return box.get(_serverIpKey) as String?;
    } catch (e) {
      debugPrint('Failed to read server address: $e');
      return null;
    }
  }

  // --- COLORS TOGGLE PERSISTENCE (UNENCRYPTED / PERSISTENT) ---
  static Future<void> saveColorsToggle(bool value) async {
    try {
      final box = _getSettingsBox();
      await box.put(_colorsToggle, value.toString());
    } catch (e) {
      debugPrint('Failed to write colors toggle: $e');
    }
  }

  static Future<String?> fetchColorsToggle() async {
    try {
      final box = _getSettingsBox();
      return box.get(_colorsToggle) as String?;
    } catch (e) {
      debugPrint('Failed to read colors toggle: $e');
      return null;
    }
  }

  // --- THE RESET IDENTITY FLOW ---
  static Future<void> resetIdentity() async {
    try {
      final identityBox = await _getIdentityBox();
      final historyBox = await _getHistoryBox();

      await identityBox.clear();
      await historyBox.clear();

      debugPrint('Identity and history cleared. Server address preserved.');
    } catch (e) {
      debugPrint('Error performing identity reset: $e');
      rethrow;
    }
  }

  // --- PERSISTENT SAVED MESSAGES STORAGE PATHS ---
  static Future<void> forwardToSavedMessages({
    required String msgId,
    required String encryptedPayload,
    required String timestampIso,
    String? mediaType,
    String? mediaFileName,
    String? localPath,
  }) async {
    try {
      final box = _getSettingsBox();
      final savedHistory = await _readMessageList(box, _savedMessagesDataKey);

      savedHistory.add({
        'id': msgId,
        'isMe': true,
        'payload': encryptedPayload,
        'timestamp': timestampIso,
        'mediaType': mediaType,
        'mediaFileName': mediaFileName,
        'localPath': localPath,
      });

      await box.put(_savedMessagesDataKey, jsonEncode(savedHistory));
    } catch (e) {
      debugPrint('Failed to write to saved messages: $e');
    }
  }

  /// Removes a single message from Saved Messages by ID. This is a purely
  /// local notebook, so unlike [deleteMessage] there's no peer to notify.
  static Future<void> deleteSavedMessage(String msgId) async {
    try {
      final box = _getSettingsBox();
      final savedHistory = await _readMessageList(box, _savedMessagesDataKey);
      savedHistory.removeWhere((m) => m['id'] == msgId);
      await box.put(_savedMessagesDataKey, jsonEncode(savedHistory));
    } catch (e) {
      debugPrint('Failed to delete saved message: $e');
    }
  }

  static List<Map<String, dynamic>> fetchSavedMessages() {
    try {
      final box = _getSettingsBox();
      final String rawJsonString = box.get(
        _savedMessagesDataKey,
        defaultValue: '[]',
      );
      final decoded = jsonDecode(rawJsonString);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (e) {
      debugPrint('Failed to read saved messages: $e');
      return [];
    }
  }

  /// Writes [bytes] to the platform's public downloads location under
  /// [fileName] and returns the full path written to. Shared by every
  /// media preview (image/audio/video/document) so "save to device" only
  /// has one implementation to get right.
  static Future<String> saveBytesToDownloads(
    String fileName,
    List<int> bytes,
  ) async {
    final targetDir = await getPublicDownloadsDirectory();
    final savePath = '${targetDir.path}/$fileName';
    final file = File(savePath);
    await file.writeAsBytes(bytes);
    return savePath;
  }

  static Future<Directory> getMediaCacheDirectory() async {
    final baseDir = await getApplicationSupportDirectory();
    final mediaDir = Directory('${baseDir.path}/media_cache');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    return mediaDir;
  }

  /// Returns a platform-friendly public download directory path.
  ///
  /// Never calls `path_provider`'s `getDownloadsDirectory()` on
  /// Android/Linux - it throws `UnsupportedError` there, and since that was
  /// previously chained with `??`, the exception was never actually caught
  /// by the `??` operator and blew straight through this function instead
  /// of falling back gracefully. On Android specifically, writing directly
  /// into the public Downloads folder can also fail with a permission
  /// error on scoped-storage devices (Android 10+), so that path is now
  /// wrapped so a permission failure falls back to the app's own
  /// (always-writable, no-permission-needed) external storage directory
  /// instead of throwing all the way up to the caller.
  static Future<Directory> getPublicDownloadsDirectory() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final androidDir = Directory('/storage/emulated/0/Download');
        try {
          if (!await androidDir.exists()) {
            await androidDir.create(recursive: true);
          }
          // Touch-test the directory is actually writable before handing
          // it back - `exists()` can return true even when writes are
          // rejected by scoped storage.
          final probe = File(
            '${androidDir.path}/.morse_write_test_${DateTime.now().microsecondsSinceEpoch}',
          );
          await probe.writeAsBytes(const [0]);
          await probe.delete();
          return androidDir;
        } catch (e) {
          debugPrint(
            'Public Downloads folder not writable ($e) - falling back to '
            'app-private external storage. Files will still be saved, just '
            'not directly visible in the system Downloads folder unless '
            'storage permission is granted to the app.',
          );
          final fallback = await getExternalStorageDirectory();
          if (fallback != null) return fallback;
        }
      } else if (!kIsWeb && Platform.isLinux) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          final linuxDownloads = Directory('$home/Downloads');
          if (await linuxDownloads.exists()) return linuxDownloads;
        }
      } else if (!kIsWeb && (Platform.isWindows || Platform.isMacOS)) {
        final dir = await getDownloadsDirectory();
        if (dir != null) return dir;
      }
    } catch (e) {
      debugPrint('Failed to resolve public downloads directory: $e');
    }

    return await getApplicationDocumentsDirectory();
  }
}
