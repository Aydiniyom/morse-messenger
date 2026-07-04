import 'dart:math';

class ChatMessage {
  final String id;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  bool isRead;

  ChatMessage(this.text, this.isMe, {DateTime? customTime, String? customId})
    : timestamp = customTime ?? DateTime.now(),
      isRead = false,
      id =
          customId ??
          "${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(10000)}";
}

class ChatPeer {
  final String rawPublicKey;
  final String shortId;
  String nickname;
  List<ChatMessage> messages = [];
  bool isPending;

  ChatPeer({required this.rawPublicKey, required this.nickname, this.isPending = false})
    : shortId = rawPublicKey.substring(rawPublicKey.length - 15);
}
