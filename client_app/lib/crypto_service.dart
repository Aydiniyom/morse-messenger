import 'dart:convert';

import 'package:crypton/crypton.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';

/// Thrown whenever an envelope fails to decrypt OR fails signature
/// verification. No need for distinction between the exceptions,
/// since the result should be the same: to drop the packet.
class EnvelopeAuthException implements Exception {
  final String message;
  const EnvelopeAuthException(this.message);

  @override
  String toString() => 'EnvelopeAuthException: $message';
}

/// Holds the result of [CryptoService.encryptMediaBytes]: the ciphertext to
/// upload to the relay, plus the AES key/IV that must travel to the
/// recipient. The key/IV are meant to be embedded as plain base64 strings
/// inside a normal envelope plaintext (see [CryptoService.encryptEnvelope])
/// so they inherit that envelope's RSA confidentiality and signature -
/// there is no need to wrap them a second time.
class MediaEncryptionResult {
  final String keyBase64;
  final String ivBase64;
  final Uint8List ciphertext;

  const MediaEncryptionResult({
    required this.keyBase64,
    required this.ivBase64,
    required this.ciphertext,
  });
}

/// All message-content cryptography for Morse Messenger lives here.
///
/// Every packet, friend requests, read receipts, chat messages, and media,
/// goes through the exact same "sign, then hybrid-encrypt" path:
///
///   1. The plaintext is signed with the sender's RSA private key
///   2. `{body, sig}` is encrypted with a fresh AES-256-GCM key (unique per
///      message).
///   3. The AES key + nonce are wrapped with the recipient's RSA public
///      key so only the recipient can unwrap them.
class CryptoService {
  CryptoService._();

  /// NIST SP 800-38D recommends a 96-bit (12-byte) nonce for GCM.
  static const int _gcmNonceBytes = 12;

  /// AES-256 key (32 bytes).
  static const int _aesKeyBytes = 32;

  /// Builds a signed, hybrid-encrypted envelope for [plaintext], addressed
  /// to [recipientPublicKey] and attributed to [senderPrivateKey].
  ///
  /// Returns a JSON string safe to place directly into [Packet.payload].
  static String encryptEnvelope({
    required String plaintext,
    required RSAPublicKey recipientPublicKey,
    required RSAPrivateKey senderPrivateKey,
  }) {
    final signature = senderPrivateKey.createSHA256Signature(
      Uint8List.fromList(utf8.encode(plaintext)),
    );

    final signedBody = jsonEncode({
      'body': plaintext,
      'sig': base64Encode(signature),
    });

    final aesKey = enc.Key.fromSecureRandom(_aesKeyBytes);
    final iv = enc.IV.fromSecureRandom(_gcmNonceBytes);
    final encrypter = enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.gcm));
    final ciphertext = encrypter.encrypt(signedBody, iv: iv);

    final keyBundle = jsonEncode({'key': aesKey.base64, 'iv': iv.base64});
    final encryptedKeyBundle = recipientPublicKey.encrypt(keyBundle);

    return jsonEncode({
      'v': 2, // envelope format version - bump if the shape ever changes
      'encryptedAesKey': encryptedKeyBundle,
      'ciphertext': ciphertext.base64,
    });
  }

  /// Reverses [encryptEnvelope] and verifies the embedded signature was
  /// produced by [expectedSenderPublicKey].
  ///
  /// Throws [EnvelopeAuthException] on any failure.
  /// malformed envelope JSON, an RSA key-bundle that doesn't decrypt, a GCM
  /// auth-tag mismatch (probably means tampering), or a signature that doesn't
  /// verify against the claimed sender. Callers should catch this one exception
  /// type and simply drop the packet.
  static String decryptEnvelope({
    required String rawEnvelope,
    required RSAPrivateKey myPrivateKey,
    required RSAPublicKey expectedSenderPublicKey,
  }) {
    try {
      final envelope = jsonDecode(rawEnvelope);
      if (envelope is! Map<String, dynamic>) {
        throw const EnvelopeAuthException('envelope is not a JSON object');
      }

      final encryptedKeyBundle = envelope['encryptedAesKey'];
      final ciphertextB64 = envelope['ciphertext'];
      if (encryptedKeyBundle is! String || ciphertextB64 is! String) {
        throw const EnvelopeAuthException('envelope missing required fields');
      }

      final keyBundleJson = myPrivateKey.decrypt(encryptedKeyBundle);
      final keyBundle = jsonDecode(keyBundleJson);
      if (keyBundle is! Map<String, dynamic>) {
        throw const EnvelopeAuthException('key bundle is not a JSON object');
      }

      final keyB64 = keyBundle['key'];
      final ivB64 = keyBundle['iv'];
      if (keyB64 is! String || ivB64 is! String) {
        throw const EnvelopeAuthException('key bundle missing key/iv');
      }

      final aesKey = enc.Key.fromBase64(keyB64);
      final iv = enc.IV.fromBase64(ivB64);
      final encrypter = enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.gcm));

      // Throws if the GCM authentication tag doesn't match; i.e. if the
      // ciphertext was tampered with in.
      final signedBodyJson = encrypter.decrypt64(ciphertextB64, iv: iv);

      final signedBody = jsonDecode(signedBodyJson);
      if (signedBody is! Map<String, dynamic>) {
        throw const EnvelopeAuthException('signed body is not a JSON object');
      }

      final body = signedBody['body'];
      final sigB64 = signedBody['sig'];
      if (body is! String || sigB64 is! String) {
        throw const EnvelopeAuthException('signed body missing body/sig');
      }

      final verified = expectedSenderPublicKey.verifySHA256Signature(
        Uint8List.fromList(utf8.encode(body)),
        base64Decode(sigB64),
      );

      if (!verified) {
        throw const EnvelopeAuthException('signature verification failed');
      }

      return body;
    } on EnvelopeAuthException {
      rethrow;
    } catch (e) {
      // Wrap absolutely everything else (FormatException, RSA library
      // errors, base64 errors, ...) into the single exception type callers
      // are expected to handle.
      throw EnvelopeAuthException('envelope processing failed: $e');
    }
  }

  /// Encrypts raw media bytes (an image/audio/video/document's content)
  /// with a fresh, single-use AES-256-GCM key. Unlike [encryptEnvelope],
  /// this does NOT RSA-wrap the key itself - the ciphertext is meant to be
  /// uploaded to the relay over HTTP, while the returned key/IV are meant
  /// to be embedded inside a normal signed-and-encrypted envelope (so they
  /// still only ever reach the intended recipient, just via the existing
  /// message channel instead of a second RSA operation).
  static MediaEncryptionResult encryptMediaBytes(Uint8List plaintextBytes) {
    final aesKey = enc.Key.fromSecureRandom(_aesKeyBytes);
    final iv = enc.IV.fromSecureRandom(_gcmNonceBytes);
    final encrypter = enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encryptBytes(plaintextBytes, iv: iv);

    return MediaEncryptionResult(
      keyBase64: aesKey.base64,
      ivBase64: iv.base64,
      ciphertext: encrypted.bytes,
    );
  }

  /// Reverses [encryptMediaBytes]. Throws [EnvelopeAuthException] if the
  /// GCM authentication tag doesn't match (tampered/corrupted ciphertext,
  /// or a key/IV mismatch) - identical failure semantics to
  /// [decryptEnvelope] so callers can handle both the same way.
  static Uint8List decryptMediaBytes({
    required Uint8List ciphertext,
    required String keyBase64,
    required String ivBase64,
  }) {
    try {
      final aesKey = enc.Key.fromBase64(keyBase64);
      final iv = enc.IV.fromBase64(ivBase64);
      final encrypter = enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.gcm));
      final decrypted = encrypter.decryptBytes(
        enc.Encrypted(ciphertext),
        iv: iv,
      );
      return Uint8List.fromList(decrypted);
    } catch (e) {
      throw EnvelopeAuthException('media decryption failed: $e');
    }
  }

  /// Runs heavy media-byte encryption in a background Isolate via compute,
  /// keeping the UI thread smooth for large attachments.
  static Future<MediaEncryptionResult> encryptMediaBytesInBackground(
    Uint8List plaintextBytes,
  ) {
    return compute(_backgroundEncryptMediaTask, plaintextBytes);
  }

  static MediaEncryptionResult _backgroundEncryptMediaTask(Uint8List bytes) {
    return encryptMediaBytes(bytes);
  }

  /// Runs heavy media-byte decryption in a background Isolate via compute.
  static Future<Uint8List> decryptMediaBytesInBackground({
    required Uint8List ciphertext,
    required String keyBase64,
    required String ivBase64,
  }) {
    return compute(_backgroundDecryptMediaTask, {
      'ciphertext': ciphertext,
      'keyBase64': keyBase64,
      'ivBase64': ivBase64,
    });
  }

  static Uint8List _backgroundDecryptMediaTask(Map<String, Object> args) {
    return decryptMediaBytes(
      ciphertext: args['ciphertext'] as Uint8List,
      keyBase64: args['keyBase64'] as String,
      ivBase64: args['ivBase64'] as String,
    );
  }

  /// Runs heavy media encryption in a background Isolate using compute.
  /// This keeps the main UI thread running at a smooth framerate.
  static Future<String> encryptEnvelopeInBackground({
    required String plaintext,
    required String recipientPublicKeyPem,
    required String senderPrivateKeyPem,
  }) async {
    // Flutter's compute helper to spawn an Isolate automatically
    return await compute(_backgroundEncryptTask, {
      'plaintext': plaintext,
      'recipientPublicKeyPem': recipientPublicKeyPem,
      'senderPrivateKeyPem': senderPrivateKeyPem,
    });
  }

  /// Entry point running entirely inside the background Isolate.
  static String _backgroundEncryptTask(Map<String, String> args) {
    final String plaintext = args['plaintext']!;
    final String recipientPem = args['recipientPublicKeyPem']!;
    final String senderPem = args['senderPrivateKeyPem']!;

    final recipientPublicKey = RSAPublicKey.fromString(recipientPem);
    final senderPrivateKey = RSAPrivateKey.fromString(senderPem);

    // Call the original, synchronous encryptEnvelope on the background thread
    return encryptEnvelope(
      plaintext: plaintext,
      recipientPublicKey: recipientPublicKey,
      senderPrivateKey: senderPrivateKey,
    );
  }
}
