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

  // --- GROUP CHAT PROFILE INDEX ---
  //
  // Stored in the same encrypted identity box as the peer list, keyed
  // separately so the two schemas (a peer's shape vs. a group's shape)
  // never collide. A group's message history is persisted through the
  // exact same [persistEncryptedMessage]/[fetchHistory]/[deleteMessage]
  // calls used for peers - callers just pass the group's ID in wherever
  // those functions expect a peer's public key, since both are really
  // just "the string this conversation is filed under".
  static const _groupListKey = 'saved_chat_groups_list';

  static Future<void> saveGroupList(
    List<Map<String, dynamic>> serializedGroups,
  ) async {
    try {
      final box = await _getIdentityBox();
      await box.put(_groupListKey, jsonEncode(serializedGroups));
    } catch (e) {
      debugPrint('Failed to write group list: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> fetchGroupList() async {
    try {
      final box = await _getIdentityBox();
      final String? rawJson = box.get(_groupListKey) as String?;
      if (rawJson == null) return [];

      final decodedList = jsonDecode(rawJson);
      if (decodedList is! List) return [];

      return decodedList
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (e) {
      debugPrint('Failed to read group list: $e');
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
    bool? isRead,
    bool? isEdited,
    String? mediaType,
    String? mediaFileName,
    String? mediaId,
    String? mediaKeyBase64,
    String? mediaIvBase64,
    String? localPath,
    Map<String, Set<String>>? reactions,
    Set<String>? readByKeys,
    String? senderKey,
    String? replyToId,
    String? replyToText,
    String? replyToSenderKey,
    bool? replyToIsMedia,
    String? replyToMediaType,
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
        // Preserve whatever read state was already persisted unless the
        // caller is explicitly reporting a change, and otherwise default
        // to "not read yet" for a brand new record. This used to be
        // hardcoded to `isMe`, which silently threw away the real read
        // status on every unrelated update (e.g. a reaction), made every
        // received message look "unread" again after any restart, and
        // made every message *I* sent look already "read" by the
        // recipient the instant it was saved.
        'isRead': isRead ?? (existing['isRead'] as bool? ?? false),
        'isEdited': isEdited ?? (existing['isEdited'] as bool? ?? false),
        'mediaType': mediaType ?? existing['mediaType'],
        'mediaFileName': mediaFileName ?? existing['mediaFileName'],
        'mediaId': mediaId ?? existing['mediaId'],
        'mediaKeyBase64': mediaKeyBase64 ?? existing['mediaKeyBase64'],
        'mediaIvBase64': mediaIvBase64 ?? existing['mediaIvBase64'],
        'localPath': localPath ?? existing['localPath'],
        'reactions': reactions != null
            ? reactions.map((emoji, keys) => MapEntry(emoji, keys.toList()))
            : existing['reactions'],
        'readByKeys': readByKeys != null
            ? readByKeys.toList()
            : existing['readByKeys'],
        'senderKey': senderKey ?? existing['senderKey'],
        'replyToId': replyToId ?? existing['replyToId'],
        'replyToText': replyToText ?? existing['replyToText'],
        'replyToSenderKey': replyToSenderKey ?? existing['replyToSenderKey'],
        'replyToIsMedia': replyToIsMedia ?? existing['replyToIsMedia'] ?? false,
        'replyToMediaType': replyToMediaType ?? existing['replyToMediaType'],
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
    String? replyToId,
    String? replyToText,
    String? replyToSenderKey,
    bool replyToIsMedia = false,
    String? replyToMediaType,
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
        'replyToId': replyToId,
        'replyToText': replyToText,
        'replyToSenderKey': replyToSenderKey,
        'replyToIsMedia': replyToIsMedia,
        'replyToMediaType': replyToMediaType,
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

  /// Updates the text of an already-saved message and marks it edited.
  /// Like [deleteSavedMessage], this is purely local - Saved Messages has
  /// no peer to notify of the change. No-op if [msgId] isn't found.
  static Future<void> editSavedMessage(String msgId, String newText) async {
    try {
      final box = _getSettingsBox();
      final savedHistory = await _readMessageList(box, _savedMessagesDataKey);
      final index = savedHistory.indexWhere((m) => m['id'] == msgId);
      if (index == -1) return;
      savedHistory[index] = {
        ...savedHistory[index],
        'payload': newText,
        'isEdited': true,
      };
      await box.put(_savedMessagesDataKey, jsonEncode(savedHistory));
    } catch (e) {
      debugPrint('Failed to edit saved message: $e');
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
  ///
  /// [fileName] is sanitized first since it can originate from a remote
  /// peer's `mediaFileName` - without that, a peer could send something
  /// like `"../../../../some/other/app/file"` and write outside the
  /// downloads folder entirely.
  static Future<String> saveBytesToDownloads(
    String fileName,
    List<int> bytes,
  ) async {
    final targetDir = await getPublicDownloadsDirectory();
    final savePath = '${targetDir.path}/${sanitizeFileName(fileName)}';
    final file = File(savePath);
    await file.writeAsBytes(bytes);
    return savePath;
  }

  /// Reduces a (possibly attacker-controlled, e.g. a filename a remote
  /// peer attached to a media message) string down to a single safe path
  /// segment: no directory traversal, no absolute paths, no separators of
  /// either flavor, and no unexpected characters. Always returns something
  /// non-empty and usable, falling back to [fallback] if nothing safe is
  /// left after stripping.
  static String sanitizeFileName(String? rawName, {String fallback = 'attachment'}) {
    final name = (rawName ?? '').trim();
    if (name.isEmpty) return fallback;

    // Keep only the final path segment, regardless of which platform's
    // separator (or both) the string used - this alone defeats
    // "../../etc/passwd"-style traversal and absolute paths.
    final lastSegment = name.split(RegExp(r'[\\/]')).last.trim();
    if (lastSegment.isEmpty || lastSegment == '.' || lastSegment == '..') {
      return fallback;
    }

    // Drop anything outside a conservative, cross-platform-safe character
    // set so the name can't smuggle in null bytes, alternate separators,
    // or other filesystem-special characters.
    final cleaned = lastSegment.replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return fallback;

    // Bound the length so it can't be used to blow past filesystem
    // path-length limits either.
    return cleaned.length > 200 ? cleaned.substring(0, 200) : cleaned;
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
