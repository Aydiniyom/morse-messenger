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

  /// Raw public key of whoever actually sent this message, when it's known
  /// and different from a simple "me vs. the one peer I'm talking to"
  /// relationship - i.e. for group messages, where a bubble can come from
  /// any member. Null for every 1:1 message and for anything you sent
  /// yourself; the UI only shows a sender label when this is set.
  final String? senderKey;

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
    this.senderKey,
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

  /// True if this entry represents a group chat rather than a 1:1 contact.
  /// When true, [rawPublicKey] holds the group's locally-generated ID
  /// (not an RSA public key) and [groupMemberKeys] holds the raw public
  /// keys of every other member - everything needed to encrypt a message
  /// once per member, the same way a 1:1 message is encrypted once for its
  /// one recipient.
  final bool isGroup;
  final List<String> groupMemberKeys;

  ChatPeer({
    required this.rawPublicKey,
    required this.nickname,
    this.isPending = false,
    this.isGroup = false,
    this.groupMemberKeys = const [],
  }) : shortId = rawPublicKey.substring(rawPublicKey.length - 15);
}
