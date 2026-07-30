import 'dart:math';

class ChatMessage {
  final String id;
  /// Mutable - unlike most other message fields, an edit updates this in
  /// place on the same [ChatMessage] instance rather than replacing it,
  /// same reasoning as [isRead]/[reactions] already being mutable.
  String text;
  final bool isMe;
  final DateTime timestamp;
  bool isRead;

  /// True once this message has been edited (by me, or - for a message
  /// someone else sent - by its original author). Purely cosmetic: it just
  /// drives the "(edited)" label next to the timestamp.
  bool isEdited;

  final String? mediaType;
  final String? mediaFileName;

  final String? mediaId;
  final String? mediaKeyBase64;
  final String? mediaIvBase64;

  String? localPath;
  double uploadProgress; // 0.0 to 1.0
  bool isTransferring;
  bool isCancelled;

  bool downloadFailed;

  /// True if this is an outgoing message (text or media) whose delivery
  /// failed - most commonly because the relay connection dropped mid-send
  /// (e.g. the app was briefly backgrounded by the OS file picker). Lets
  /// the UI show a clear "tap to retry" affordance instead of the message
  /// silently vanishing or looking sent when it wasn't.
  bool sendFailed;

  Map<String, Set<String>> reactions;

  final String? senderKey;

  /// The id of the message this one is replying to, or null if it isn't a
  /// reply. Set once at construction and never mutated afterward, same as
  /// [id] - a reply always points at whatever message was selected at the
  /// moment "Reply" was tapped/swiped.
  final String? replyToId;

  /// A snapshot of the replied-to message's preview text, captured at
  /// reply time and carried in the wire payload itself (see
  /// `ChatSessionManager.sendChatMessage`). This means the quoted preview
  /// still renders correctly even if the original message is later
  /// deleted locally, or hasn't arrived/synced yet on this device.
  final String? replyToText;

  /// The raw public key of whoever originally sent the replied-to message.
  /// Comparing this against the viewer's own key (same pattern as
  /// [senderKey]) is enough to label the quote "You" vs. someone else's
  /// name, for both 1:1 and group chats.
  final String? replyToSenderKey;

  /// Whether the replied-to message was a media attachment, so the quoted
  /// preview can fall back to a "📷 Photo"-style label when there was no
  /// caption text to show.
  final bool replyToIsMedia;

  /// The replied-to message's media type ('image'/'video'/'audio'/
  /// 'document'), used only to pick the right fallback label above.
  final String? replyToMediaType;

  /// For a group message I sent (`isMe == true` on a group chat), the raw
  /// public keys of every other member who has sent back a read receipt
  /// for it. A group has more than one "other side", so unlike a 1:1 chat
  /// a single [isRead] bool can't represent the read state - the UI
  /// instead treats the message as fully read once this set covers every
  /// other current member. Unused (stays empty) for 1:1 messages and for
  /// messages that aren't mine.
  Set<String> readByKeys;

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
    this.sendFailed = false,
    this.isEdited = false,
    Map<String, Set<String>>? reactions,
    this.senderKey,
    Set<String>? readByKeys,
    this.replyToId,
    this.replyToText,
    this.replyToSenderKey,
    this.replyToIsMedia = false,
    this.replyToMediaType,
  }) : timestamp = customTime ?? DateTime.now(),
       isRead = false,
       reactions = reactions ?? {},
       readByKeys = readByKeys ?? {},
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

  /// True if notifications for this contact/group are muted. For a group,
  /// this doesn't silence it entirely - a message that actually @mentions
  /// you (or @everyone) still notifies, same as an unmuted group; muting
  /// only suppresses the "someone posted" notification for messages that
  /// don't involve you directly. For a DM, muting suppresses notifications
  /// entirely, since every message in a DM is inherently "about you".
  bool isMuted;

  /// True if this entry represents a group chat rather than a 1:1 contact.
  /// When true, [rawPublicKey] holds the group's locally-generated ID
  /// (not an RSA public key) and [groupMemberKeys] holds the raw public
  /// keys of every other member.
  final bool isGroup;
  List<String> groupMemberKeys;

  /// Public keys explicitly permitted to join this group. Anyone already a
  /// member can extend this list from the group settings dialog (long
  /// press the group name). It's what [groupIntroducerKey]'s device checks
  /// a `groupJoinRequest` against before admitting a new member. Meaningless
  /// for 1:1 peers.
  List<String> allowedJoinerKeys;

  /// A random, per-group secret that - together with [rawPublicKey] (the
  /// group ID) - makes up the invite code. It never changes and is always
  /// viewable/copyable from the group settings dialog, unlike the old
  /// invite codes this replaces, which had to be regenerated every time
  /// membership changed because they embedded the entire member list.
  /// Knowing the secret is necessary but not sufficient to join - the
  /// joiner's key must also be on [allowedJoinerKeys] - so leaking the
  /// invite code alone doesn't let a stranger in.
  String? groupInviteSecret;

  /// The member whose device actually evaluates join requests (verifies
  /// the secret, checks the allow-list, and admits new members). Always
  /// the group's creator in this implementation, and embedded in the
  /// invite code so a joiner knows who to address their request to.
  String? groupIntroducerKey;

  ChatPeer({
    required this.rawPublicKey,
    required this.nickname,
    this.isPending = false,
    this.isMuted = false,
    this.isGroup = false,
    List<String>? groupMemberKeys,
    List<String>? allowedJoinerKeys,
    this.groupInviteSecret,
    this.groupIntroducerKey,
  }) : groupMemberKeys = groupMemberKeys ?? [],
       allowedJoinerKeys = allowedJoinerKeys ?? [],
       shortId = rawPublicKey.substring(rawPublicKey.length - 15);
}
