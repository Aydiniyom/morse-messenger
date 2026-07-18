import 'dart:math';

class ChatMessage {
  final String id;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  bool isRead;

  final String? mediaType;
  final String? mediaFileName;

  /// Identifies the encrypted blob on the relay's HTTP media store, plus
  /// the AES-256-GCM key/IV needed to decrypt it after downloading. These
  /// are what let media be fetched (or re-fetched, if the local cache was
  /// cleared) instead of ever needing to travel embedded in a packet.
  final String? mediaId;
  final String? mediaKeyBase64;
  final String? mediaIvBase64;

  String? localPath;
  double uploadProgress; // 0.0 to 1.0
  bool isTransferring;
  bool isCancelled;

  /// True if the most recent attempt to download+decrypt this message's
  /// media failed (network error, expired relay copy, tampering, ...), so
  /// the UI can offer a retry instead of silently showing nothing.
  bool downloadFailed;

  /// Emoji reactions on this message, keyed by the emoji itself, with each
  /// value being the set of raw public keys of everyone who reacted with
  /// that emoji. A single reactor key can appear under multiple emojis (you
  /// can stack more than one reaction onto the same message), and each
  /// emoji can carry multiple reactor keys - so this already generalizes to
  /// group chats without any format change, even though today there's only
  /// ever "me" and one peer to populate it.
  Map<String, Set<String>> reactions;

  ChatMessage(
    this.text,
    this.isMe, {
    DateTime? customTime,
    String? customId,
    this.mediaType,
    this.mediaFileName,
    this.mediaId,
    this.mediaKeyBase64,
    this.mediaIvBase64,
    this.localPath,
    this.uploadProgress = 0.0,
    this.isTransferring = false,
    this.isCancelled = false,
    this.downloadFailed = false,
    Map<String, Set<String>>? reactions,
  }) : timestamp = customTime ?? DateTime.now(),
       isRead = false,
       reactions = reactions ?? {},
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
