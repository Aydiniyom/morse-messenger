class ChatMessage {
  final String text;
  final bool isMe;
  ChatMessage(this.text, this.isMe);
}

class ChatPeer {
  final String rawPublicKey;
  final String shortId;
  String nickname;
  List<ChatMessage> messages = [];
  ChatPeer(this.rawPublicKey, this.nickname) 
    : shortId = rawPublicKey.substring(rawPublicKey.length - 15);
}