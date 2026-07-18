import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thrown when a media upload or download fails at the transport level
/// (network error, relay-side rejection, unexpected status code, ...).
class MediaTransferException implements Exception {
  final String message;
  const MediaTransferException(this.message);

  @override
  String toString() => 'MediaTransferException: $message';
}

/// Moves already end-to-end-encrypted media ciphertext to/from the relay
/// over plain HTTP POST/GET, instead of embedding it as base64 inside a
/// WebSocket JSON packet.
///
/// The relay never sees plaintext here either - by the time bytes reach
/// this class they've already been through [CryptoService.encryptMediaBytes]
/// - this class is purely about transport, not confidentiality. Moving
/// media off the WebSocket and onto HTTP avoids the ~33% size inflation of
/// base64, lets both ends stream the payload instead of holding an entire
/// base64-encoded JSON string in memory, and keeps large transfers from
/// blocking the same socket carrying live presence/read-receipt traffic.
class MediaService {
  MediaService._();

  static const Duration _requestTimeout = Duration(minutes: 10);

  /// Mirrors [ChatSessionManager._resolveWebSocketUrl], but returns an
  /// http(s) base URL (no trailing path) instead of a ws(s):// one, since
  /// media transfer uses plain HTTP against the same relay host/port.
  static Uri _resolveMediaUri(String rawAddress, String path) {
    String host = rawAddress.trim();
    String scheme = 'http';

    if (host.startsWith('wss://')) {
      scheme = 'https';
      host = host.substring('wss://'.length);
    } else if (host.startsWith('ws://')) {
      scheme = 'http';
      host = host.substring('ws://'.length);
    } else if (host.startsWith('https://')) {
      scheme = 'https';
      host = host.substring('https://'.length);
    } else if (host.startsWith('http://')) {
      scheme = 'http';
      host = host.substring('http://'.length);
    }

    // Strip a trailing "/ws" (or any trailing path) the user may have
    // typed as part of the server address - media endpoints live at a
    // fixed path on the same host/port, not under /ws.
    final slashIndex = host.indexOf('/');
    if (slashIndex != -1) {
      host = host.substring(0, slashIndex);
    }

    return Uri.parse('$scheme://$host$path');
  }

  /// Uploads already-encrypted [ciphertext] to the relay and returns the
  /// opaque media ID the relay assigned it. Streams the bytes rather than
  /// building an intermediate base64/JSON string.
  static Future<String> uploadEncryptedMedia({
    required String serverIp,
    required Uint8List ciphertext,
  }) async {
    final uri = _resolveMediaUri(serverIp, '/media/upload');

    try {
      final request = http.StreamedRequest('POST', uri)
        ..headers['Content-Type'] = 'application/octet-stream'
        ..contentLength = ciphertext.length;

      // http.StreamedRequest streams this straight into the socket as it's
      // sent, rather than buffering an entire base64/JSON body up front the
      // way the old WebSocket path did.
      request.sink.add(ciphertext);
      unawaited(request.sink.close());

      final streamedResponse = await request.send().timeout(_requestTimeout);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        throw MediaTransferException(
          'upload rejected by relay (HTTP ${response.statusCode})',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['id'] is! String) {
        throw const MediaTransferException('relay returned a malformed upload response');
      }
      return decoded['id'] as String;
    } on MediaTransferException {
      rethrow;
    } catch (e) {
      throw MediaTransferException('upload failed: $e');
    }
  }

  /// Downloads the encrypted blob previously stored under [mediaId].
  static Future<Uint8List> downloadEncryptedMedia({
    required String serverIp,
    required String mediaId,
  }) async {
    final uri = _resolveMediaUri(serverIp, '/media/download/$mediaId');

    try {
      final response = await http.get(uri).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        throw MediaTransferException(
          'download rejected by relay (HTTP ${response.statusCode})',
        );
      }
      return response.bodyBytes;
    } on MediaTransferException {
      rethrow;
    } catch (e) {
      throw MediaTransferException('download failed: $e');
    }
  }
}
