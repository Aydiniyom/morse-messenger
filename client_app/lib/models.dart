import 'dart:math';

class ChatMessage {
  final String id;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  bool isRead;

  final String? mediaType;
  final String? mediaFileName;
  final String? base64Data;
  String? localPath;

  ChatMessage(
    this.text,
    this.isMe, {
    DateTime? customTime,
    String? customId,
    this.mediaType,
    this.mediaFileName,
    this.base64Data,
    this.localPath,
  }) : timestamp = customTime ?? DateTime.now(),
       isRead = false,
       id =
           customId ??
           "${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(10000)}";

  bool get isMedia => mediaType != null;
}

class ChatPeer {
  final String rawPublicKey;
  final String shortId;
  String nickname;
  List<ChatMessage> messages = [];
  bool isPending;

  ChatPeer({
    required this.rawPublicKey,
    required this.nickname,
    this.isPending = false,
  }) : shortId = rawPublicKey.substring(rawPublicKey.length - 15);
}
