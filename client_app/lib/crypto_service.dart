import 'dart:convert';
import 'dart:typed_data';

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
