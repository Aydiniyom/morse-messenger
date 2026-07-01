import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageService {
  static const _secureStorage = FlutterSecureStorage();
  static const _boxName = 'secure_chat_box';
  static const _keyName = 'dec_chat_private_key';
  static const _hiveSecretKeyName = 'hive_aes_encryption_key';

  // initializes Hive and opens the encrypted box safely
  static Future<Box> _getEncryptedBox() async {
    await Hive.initFlutter();
    
    List<int> encryptionKey;
    try {
      // try to read an existing AES encryption key from secure storage
      final savedKeyString = await _secureStorage.read(key: _hiveSecretKeyName);
      if (savedKeyString != null) {
        encryptionKey = base64Url.decode(savedKeyString);
      } else {
        // generate a brand new 256-bit key if it doesn't exist yet
        encryptionKey = Hive.generateSecureKey();
        await _secureStorage.write(
          key: _hiveSecretKeyName, 
          value: base64Url.encode(encryptionKey),
        );
      }
    } catch (e) {
      debugPrint("OS Keyring locked. Using a deterministic fallback encryption key: $e");
      // FALLBACK: create a stable 32-byte key so the app doesn't crash
      encryptionKey = List<int>.generate(32, (i) => (i + 42) % 256);
    }

    // open the box using the AES-256 encryption cipher
    return await Hive.openBox(
      _boxName, 
      encryptionCipher: HiveAesCipher(encryptionKey),
    );
  }

  static Future<String?> readPrivateKey() async {
    try {
      final box = await _getEncryptedBox();
      return box.get(_keyName) as String?;
    } catch (e) {
      debugPrint("Error reading from encrypted Hive box: $e");
      return null;
    }
  }

  static Future<void> savePrivateKey(String pemValue) async {
    try {
      final box = await _getEncryptedBox();
      await box.put(_keyName, pemValue);
    } catch (e) {
      debugPrint("Error writing to encrypted Hive box: $e");
    }
  }
}