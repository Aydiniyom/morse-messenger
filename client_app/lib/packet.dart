import 'dart:convert';

/// The set of packet types exchanged with the relay server.
enum PacketType {
  register,
  message,
  statusUpdate;

  static PacketType? tryParse(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'register':
        return PacketType.register;
      case 'message':
        return PacketType.message;
      case 'status_update':
        return PacketType.statusUpdate;
      default:
        return null;
    }
  }

  String get wireValue {
    switch (this) {
      case PacketType.register:
        return 'register';
      case PacketType.message:
        return 'message';
      case PacketType.statusUpdate:
        return 'status_update';
    }
  }
}

/// Thrown when a packet arriving from the network is malformed, oversized,
/// or otherwise fails validation.
class MalformedPacketException implements Exception {
  final String reason;
  const MalformedPacketException(this.reason);

  @override
  String toString() => 'MalformedPacketException: $reason';
}

/// The outer, transport-level envelope sent to/from the relay server.
///
/// The relay server only ever sees [type], [fromUser], [toUser], and the
/// opaque [payload] string - it cannot read message contents. All
/// confidentiality/integrity/authenticity guarantees are provided
/// end-to-end by `CryptoService`.
class Packet {
  /// A generous bound for identity strings (PEM-ish public keys). Anything
  /// larger is almost certainly a malformed or malicious packet, not a
  /// legitimate key.
  static const int maxIdentityLength = 4096;

  /// Bounds the payload so a single malicious/buggy peer can't force the
  /// app to buffer unbounded data in memory. 12 MB comfortably covers a
  /// hybrid-encrypted chat message with a modest file attachment.
  static const int maxPayloadLength = 12 * 1024 * 1024;

  final PacketType type;
  final String fromUser;
  final String toUser;
  final String payload;

  const Packet({
    required this.type,
    required this.fromUser,
    required this.toUser,
    required this.payload,
  });

  Map<String, dynamic> toJson() => {
        'type': type.wireValue,
        'fromUser': fromUser,
        'toUser': toUser,
        'payload': payload,
      };

  String encode() => jsonEncode(toJson());

  /// Parses and validates a raw wire packet.
  factory Packet.decode(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw MalformedPacketException('invalid JSON: $e');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const MalformedPacketException('packet is not a JSON object');
    }

    final type = PacketType.tryParse(decoded['type']);
    if (type == null) {
      throw MalformedPacketException('unknown packet type: ${decoded['type']}');
    }

    final fromUserRaw = decoded['fromUser'];
    final toUserRaw = decoded['toUser'];
    final payloadRaw = decoded['payload'];

    if (fromUserRaw is! String || fromUserRaw.trim().isEmpty) {
      throw const MalformedPacketException('missing/empty fromUser');
    }
    if (toUserRaw is! String) {
      throw const MalformedPacketException('missing toUser');
    }
    if (payloadRaw is! String) {
      throw const MalformedPacketException('missing/invalid payload');
    }

    final fromUser = fromUserRaw.trim();
    final toUser = toUserRaw.trim();

    if (fromUser.length > maxIdentityLength) {
      throw const MalformedPacketException('fromUser exceeds max length');
    }
    if (payloadRaw.length > maxPayloadLength) {
      throw const MalformedPacketException('payload exceeds max length');
    }

    return Packet(
      type: type,
      fromUser: fromUser,
      toUser: toUser,
      payload: payloadRaw,
    );
  }
}
