import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageService {
  static const _secureStorage = FlutterSecureStorage();
  static const _keyName = 'user_private_key_pem';

  static Future<void> savePrivateKey(String privateKeyPem) async {
    await _secureStorage.write(key: _keyName, value: privateKeyPem);
  }

  static Future<String?> readPrivateKey() async {
    return await _secureStorage.read(key: _keyName);
  }
}