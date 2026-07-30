import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:crypton/crypton.dart';

import 'crypto_service.dart';
import 'media_service.dart';
import 'packet.dart';
import 'storage_service.dart';

/// Owns the WebSocket connection to the relay server and all message
/// send/receive plumbing.
///
/// Responsibilities:
///  - connection lifecycle (connect / reconnect / disconnect)
///  - wire-format (de)serialization via [Packet]
///  - delegating all actual cryptography to [CryptoService]
///  - routing verified, decrypted payloads to the callbacks the UI layer
///    supplied
class ChatSessionManager {
  final String serverIp;
  final String myRawPublicKey;
  final RSAPrivateKey privKey;

  final VoidCallback onStateChanged;
  final void Function(String senderKey) onFriendRequestReceived;
  final void Function(
    String senderKey,
    String text,
    Map<String, dynamic> payload,
  )
  onMessageReceived;
  final void Function(String senderKey, String msgId) onReadReceiptReceived;
  final void Function(String senderKey) onFriendRequestAccepted;
  final void Function(Set<String> onlinePeers) onStatusUpdateReceived;
  final void Function(String senderKey, String msgId) onMessageDeleted;
  final void Function(
    String senderKey,
    String msgId,
    String emoji,
    bool isAdd,
  )
  onReactionReceived;

  /// Fires when the original author of message [msgId] changes its text -
  /// "edit for everyone", same delivery/authenticity model as
  /// [onMessageDeleted] (the envelope's verified sender is who's allowed to
  /// have sent this; whether they were actually the message's original
  /// author is the caller's job to check, same as delete already is).
  final void Function(String senderKey, String msgId, String newText)
  onMessageEdited;

  /// Fires for an inbound group message - [senderKey] is whichever member
  /// actually sent it (not necessarily anyone in particular), [groupId]
  /// identifies which group it belongs to, and [payload] is the same
  /// decrypted JSON map [onMessageReceived] gets, just with `isGroupMessage`
  /// and `groupId` added to it.
  final void Function(
    String senderKey,
    String groupId,
    String text,
    Map<String, dynamic> payload,
  )
  onGroupMessageReceived;

  /// Fires when a group member confirms they've read one of my group
  /// messages. Mirrors [onReadReceiptReceived], just scoped to a group.
  final void Function(String senderKey, String groupId, String msgId)
  onGroupReadReceiptReceived;

  /// Fires when a group member adds or removes a reaction on a group
  /// message (mine or another member's). Mirrors [onReactionReceived],
  /// just scoped to a group and fanned out to every member the same way
  /// [sendGroupReactionUpdate] sends it.
  final void Function(
    String senderKey,
    String groupId,
    String msgId,
    String emoji,
    bool isAdd,
  )
  onGroupReactionReceived;

  /// Fires when a group member tells us to remove one of their messages
  /// (or one of ours) from a group's history - "delete for everyone",
  /// same idea as [onMessageDeleted] but scoped to a group.
  final void Function(String senderKey, String groupId, String msgId)
  onGroupMessageDeleted;

  /// Fires when a group member's message is edited by its original author.
  /// Mirrors [onMessageEdited], just scoped to a group.
  final void Function(
    String senderKey,
    String groupId,
    String msgId,
    String newText,
  )
  onGroupMessageEdited;

  /// Fires on the group's introducer device when someone asks to join.
  /// [requesterKey] is cryptographically authenticated (it's the envelope's
  /// verified sender), but whether they're actually allowed in is the
  /// caller's job to check against the group's allow-list.
  final void Function(String requesterKey, String groupId, String secret)
  onGroupJoinRequestReceived;

  /// Fires on the joiner's device once the introducer has verified the
  /// invite secret and the allow-list and admitted them. [memberKeys] is
  /// every other current member (not including the joiner), and
  /// [allowedJoinerKeys] is the introducer's authoritative allow-list at
  /// the time of admission, so the joiner's local copy starts in sync
  /// instead of empty.
  final void Function(
    String groupId,
    List<String> memberKeys,
    String groupName,
    List<String> allowedJoinerKeys,
  )
  onGroupJoinAccepted;

  /// Fires on the joiner's device if the introducer rejected the join
  /// request (bad secret, or the joiner's key isn't allow-listed).
  final void Function(String groupId) onGroupJoinRejected;

  /// Fires on an existing member's device when the introducer admits a new
  /// member, so every current member's local roster stays in sync with who
  /// can actually send/receive in the group.
  final void Function(String groupId, String newMemberKey) onGroupMemberAdded;

  /// Fires on the introducer's device when any current member (including
  /// itself) asks to extend or shrink the allow-list. The introducer is
  /// the sole source of truth for the allow-list precisely so every
  /// member's displayed count/contents can't drift apart - anyone else
  /// receiving this can safely ignore it.
  final void Function(
    String requesterKey,
    String groupId,
    List<String> addKeys,
    List<String> removeKeys,
  )
  onGroupAllowListChangeRequestReceived;

  /// Fires on every current (non-removed) member's device after the
  /// introducer processes an allow-list change. [allowedJoinerKeys] is the
  /// full authoritative list (replaces the local copy outright, rather
  /// than being merged, so a member who missed an earlier update can't
  /// stay stuck with stale data), and [removedMemberKeys] is anyone who
  /// was just kicked (their key was on the allow-list *and* was a current
  /// member) so recipients can prune their own membership roster too.
  final void Function(
    String groupId,
    List<String> allowedJoinerKeys,
    List<String> removedMemberKeys,
  )
  onGroupAllowListSyncReceived;

  /// Fires on a removed member's own device: the introducer took them off
  /// the allow-list while they were a member, so they're being kicked from
  /// the group entirely.
  final void Function(String groupId) onGroupKicked;

  ChatSessionManager({
    required this.serverIp,
    required this.myRawPublicKey,
    required this.privKey,
    required this.onStateChanged,
    required this.onFriendRequestReceived,
    required this.onMessageReceived,
    required this.onReadReceiptReceived,
    required this.onFriendRequestAccepted,
    required this.onStatusUpdateReceived,
    required this.onMessageDeleted,
    required this.onMessageEdited,
    required this.onReactionReceived,
    required this.onGroupMessageReceived,
    required this.onGroupReadReceiptReceived,
    required this.onGroupReactionReceived,
    required this.onGroupMessageDeleted,
    required this.onGroupMessageEdited,
    required this.onGroupJoinRequestReceived,
    required this.onGroupJoinAccepted,
    required this.onGroupJoinRejected,
    required this.onGroupMemberAdded,
    required this.onGroupAllowListChangeRequestReceived,
    required this.onGroupAllowListSyncReceived,
    required this.onGroupKicked,
  });

  // --- connection state -----------------------------------------------
  IOWebSocketChannel? _channel;
  bool isServerConnected = false;
  bool isConnecting = false;

  /// True once the caller has explicitly asked us to disconnect (app
  /// backgrounded, user changed server, widget disposed). While true, we
  /// never attempt to auto-reconnect; only an explicit
  /// [initializeWebSocket] call resumes activity.
  bool _manualDisconnect = false;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectDelaySeconds = 30;
  static const Duration _connectTimeout = Duration(seconds: 10);

  final Set<String> _onlinePeers = {};
  Set<String> get onlinePeers => _onlinePeers;

  /// Resolves once the socket is actually connected, or `false` if
  /// [timeout] elapses first. Exists so send paths that fire right after
  /// the app resumes (e.g. right after the OS file picker briefly
  /// backgrounded us) can wait out an in-flight reconnect instead of
  /// racing it and throwing immediately.
  Future<bool> waitUntilConnected({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (isServerConnected) return true;

    // Not connected and not even trying (e.g. manually disconnected, or
    // the reconnect timer hasn't fired yet) - kick off a connection
    // attempt ourselves rather than waiting on nothing.
    if (!isConnecting) {
      initializeWebSocket();
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isServerConnected) return true;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return isServerConnected;
  }

  // --- connection lifecycle ---------------------------------------------

  void initializeWebSocket() async {
    if (isConnecting) return;

    _manualDisconnect = false;
    _reconnectTimer?.cancel();

    // Close out any previous socket cleanly before opening a new one.
    await _channel?.sink.close();
    _channel = null;

    isConnecting = true;
    isServerConnected = false;
    onStateChanged();

    try {
      final wsUrl = _resolveWebSocketUrl(serverIp);

      final connectedChannel = IOWebSocketChannel.connect(
        Uri.parse(wsUrl),
        pingInterval: const Duration(seconds: 20),
      );

      // Guard against a server address that accepts the TCP connection but
      // never completes the WebSocket handshake (e.g. wrong port behind a
      // firewall); without this the app could hang in "connecting" state
      // forever.
      await connectedChannel.ready.timeout(_connectTimeout);

      _channel = connectedChannel;
      isServerConnected = true;
      isConnecting = false;
      _reconnectAttempts = 0;
      onStateChanged();

      StorageService.saveServerIp(serverIp);

      _send(
        Packet(
          type: PacketType.register,
          fromUser: myRawPublicKey,
          toUser: '',
          payload: '',
        ),
      );

      connectedChannel.stream.listen(
        (rawData) => _handleIncomingPacket(rawData.toString()),
        onError: (Object err) {
          debugPrint('WebSocket stream error: $err');
          _handleDisconnect(scheduleReconnect: true);
        },
        onDone: () {
          _handleDisconnect(scheduleReconnect: true);
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('WebSocket initialization failed: $e');
      _handleDisconnect(scheduleReconnect: true);
    }
  }

  /// Resolves a user-entered address ("host:port", "ws://host:port", ...)
  /// into a normalized WebSocket URL
  static String _resolveWebSocketUrl(String rawAddress) {
    if (rawAddress.startsWith('ws://') || rawAddress.startsWith('wss://')) {
      return rawAddress;
    }
    return rawAddress.endsWith('/ws')
        ? 'ws://$rawAddress'
        : 'ws://$rawAddress/ws';
  }

  void _handleDisconnect({bool scheduleReconnect = false}) {
    final wasConnected = isServerConnected || isConnecting;
    isServerConnected = false;
    isConnecting = false;

    if (wasConnected) {
      onStateChanged();
    }

    if (scheduleReconnect && !_manualDisconnect) {
      _scheduleReconnect();
    }
  }

  /// Schedules a reconnect attempt with capped exponential backoff plus
  /// jitter, so a relay server that's briefly restarting doesn't get
  /// hammered by every client at the exact same instant.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    _reconnectAttempts++;
    final baseDelaySeconds = min(
      _maxReconnectDelaySeconds,
      pow(2, _reconnectAttempts).toInt(),
    );
    final jitterMs = Random().nextInt(1000);
    final delay = Duration(seconds: baseDelaySeconds, milliseconds: jitterMs);

    debugPrint(
      'Scheduling reconnect attempt #$_reconnectAttempts in ${delay.inSeconds}s',
    );

    _reconnectTimer = Timer(delay, () {
      if (!_manualDisconnect) {
        initializeWebSocket();
      }
    });
  }

  /// Ends the session and suppresses auto-reconnect until
  /// [initializeWebSocket] is explicitly called again.
  void disconnect() {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _handleDisconnect();
  }

  /// Releases all resources. Safe to call even if never connected.
  void dispose() {
    disconnect();
  }

  // --- outgoing packets ---------------------------------------------------

  /// Sends a raw packet over the socket. Throws if there's no live
  /// connection, so callers that need "fire and forget" semantics should
  /// catch and log; callers that need the UI to know about failure (e.g.
  /// sending a chat message) can let it propagate.
  void _send(Packet packet) {
    final channel = _channel;
    if (channel == null || !isServerConnected) {
      throw StateError('Cannot send: no active connection to the relay server');
    }
    channel.sink.add(packet.encode());
  }

  void sendReadReceipt(String targetKey, String messageId) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({'isReceipt': true, 'msgId': messageId});
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send read receipt: $e');
    }
  }

  /// Tells [targetKey] that the message identified by [messageId] should be
  /// deleted on their end too. Like every other packet, this is signed and
  /// encrypted - the relay never sees which message is being removed.
  void sendDeleteNotice(String targetKey, String messageId) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({'isDelete': true, 'msgId': messageId});
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send delete notice: $e');
    }
  }

  /// Tells [targetKey] that the message identified by [messageId] now
  /// reads [newText] - "edit for everyone", same delivery/signing pattern
  /// as [sendDeleteNotice]. Only the original author should ever call
  /// this for a given message; there's nothing at the protocol level
  /// stopping anyone else, so the UI layer is what enforces that.
  void sendEditNotice(String targetKey, String messageId, String newText) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({
        'isEdit': true,
        'msgId': messageId,
        'text': newText,
      });
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send edit notice: $e');
    }
  }

  /// Like [sendReadReceipt], but tags the receipt with [groupId] so the
  /// original sender can track per-message read state across every member
  /// instead of just a single yes/no.
  void sendGroupReadReceipt(String targetKey, String groupId, String messageId) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({
        'isReceipt': true,
        'isGroupMessage': true,
        'groupId': groupId,
        'msgId': messageId,
      });
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send group read receipt: $e');
    }
  }

  /// "Delete for everyone" for a group message: sends a delete notice,
  /// individually, to every current member - same fan-out pattern as
  /// [sendGroupMessage]. One member's copy failing doesn't stop the rest.
  void sendGroupDeleteNotice(
    List<String> memberKeys,
    String groupId,
    String messageId,
  ) {
    for (final memberKey in memberKeys) {
      try {
        final recipient = RSAPublicKey.fromString(memberKey.trim());
        final plaintext = jsonEncode({
          'isDelete': true,
          'isGroupMessage': true,
          'groupId': groupId,
          'msgId': messageId,
        });
        final envelope = CryptoService.encryptEnvelope(
          plaintext: plaintext,
          recipientPublicKey: recipient,
          senderPrivateKey: privKey,
        );
        _send(
          Packet(
            type: PacketType.message,
            fromUser: myRawPublicKey,
            toUser: memberKey.trim(),
            payload: envelope,
          ),
        );
      } catch (e) {
        debugPrint('Failed to send group delete notice to a member: $e');
      }
    }
  }

  /// Fans an edit out to every current group member - same "no group
  /// packet on the wire, just one 1:1 send per member" pattern as
  /// [sendGroupDeleteNotice].
  void sendGroupEditNotice(
    List<String> memberKeys,
    String groupId,
    String messageId,
    String newText,
  ) {
    for (final memberKey in memberKeys) {
      try {
        final recipient = RSAPublicKey.fromString(memberKey.trim());
        final plaintext = jsonEncode({
          'isEdit': true,
          'isGroupMessage': true,
          'groupId': groupId,
          'msgId': messageId,
          'text': newText,
        });
        final envelope = CryptoService.encryptEnvelope(
          plaintext: plaintext,
          recipientPublicKey: recipient,
          senderPrivateKey: privKey,
        );
        _send(
          Packet(
            type: PacketType.message,
            fromUser: myRawPublicKey,
            toUser: memberKey.trim(),
            payload: envelope,
          ),
        );
      } catch (e) {
        debugPrint('Failed to send group edit notice to a member: $e');
      }
    }
  }

  /// Asks [introducerKey] (embedded in the invite code) to admit us into
  /// the group. The introducer verifies [secret] against the group's
  /// invite secret and checks our (cryptographically authenticated) key
  /// against its allow-list before responding.
  void sendGroupJoinRequest(String introducerKey, String groupId, String secret) {
    try {
      final recipient = RSAPublicKey.fromString(introducerKey.trim());
      final plaintext = jsonEncode({
        'isGroupJoinRequest': true,
        'groupId': groupId,
        'secret': secret,
      });
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: introducerKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send group join request: $e');
    }
  }

  /// Introducer -> joiner: admits them, handing back the current member
  /// roster, the group's local name, and the authoritative allow-list so
  /// their client can populate it.
  void sendGroupJoinAccepted({
    required String targetKey,
    required String groupId,
    required List<String> memberKeys,
    required String groupName,
    required List<String> allowedJoinerKeys,
  }) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({
        'isGroupJoinAccepted': true,
        'groupId': groupId,
        'groupName': groupName,
        'memberKeys': memberKeys,
        'allowedJoinerKeys': allowedJoinerKeys,
      });
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send group join acceptance: $e');
    }
  }

  /// Introducer -> joiner: rejects the request (bad secret, or the
  /// requester's key isn't on the allow-list).
  void sendGroupJoinRejected(String targetKey, String groupId) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({
        'isGroupJoinRejected': true,
        'groupId': groupId,
      });
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send group join rejection: $e');
    }
  }

  /// Introducer -> every other existing member: tells them a new member
  /// was admitted, so their local roster grows to match - otherwise the
  /// new member's messages would get silently dropped by everyone except
  /// the introducer (see the membership check in `onGroupMessageReceived`).
  void sendGroupMemberAdded(
    List<String> memberKeys,
    String groupId,
    String newMemberKey,
  ) {
    for (final memberKey in memberKeys) {
      try {
        final recipient = RSAPublicKey.fromString(memberKey.trim());
        final plaintext = jsonEncode({
          'isGroupMemberAdded': true,
          'groupId': groupId,
          'newMemberKey': newMemberKey,
        });
        final envelope = CryptoService.encryptEnvelope(
          plaintext: plaintext,
          recipientPublicKey: recipient,
          senderPrivateKey: privKey,
        );
        _send(
          Packet(
            type: PacketType.message,
            fromUser: myRawPublicKey,
            toUser: memberKey.trim(),
            payload: envelope,
          ),
        );
      } catch (e) {
        debugPrint('Failed to notify a member about the new joiner: $e');
      }
    }
  }

  /// Any member -> introducer: asks to extend or shrink the allow-list.
  /// The introducer alone decides whether/how to apply it and is
  /// responsible for re-syncing everyone afterwards - this message doesn't
  /// change anything by itself.
  void sendGroupAllowListChangeRequest({
    required String introducerKey,
    required String groupId,
    required List<String> addKeys,
    required List<String> removeKeys,
  }) {
    try {
      final recipient = RSAPublicKey.fromString(introducerKey.trim());
      final plaintext = jsonEncode({
        'isGroupAllowListChangeRequest': true,
        'groupId': groupId,
        'addKeys': addKeys,
        'removeKeys': removeKeys,
      });
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: introducerKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send allow-list change request: $e');
    }
  }

  /// Introducer -> every remaining current member: the authoritative,
  /// full allow-list after a change, plus anyone who was just kicked (was
  /// removed from the allow-list while still a member) so recipients can
  /// prune their own membership roster too. Always a full replacement,
  /// never a merge, so a member who missed an earlier update self-corrects
  /// instead of drifting further out of sync.
  void sendGroupAllowListSync(
    List<String> memberKeys,
    String groupId,
    List<String> allowedJoinerKeys,
    List<String> removedMemberKeys,
  ) {
    for (final memberKey in memberKeys) {
      try {
        final recipient = RSAPublicKey.fromString(memberKey.trim());
        final plaintext = jsonEncode({
          'isGroupAllowListSync': true,
          'groupId': groupId,
          'allowedJoinerKeys': allowedJoinerKeys,
          'removedMemberKeys': removedMemberKeys,
        });
        final envelope = CryptoService.encryptEnvelope(
          plaintext: plaintext,
          recipientPublicKey: recipient,
          senderPrivateKey: privKey,
        );
        _send(
          Packet(
            type: PacketType.message,
            fromUser: myRawPublicKey,
            toUser: memberKey.trim(),
            payload: envelope,
          ),
        );
      } catch (e) {
        debugPrint('Failed to broadcast allow-list sync to a member: $e');
      }
    }
  }

  /// Introducer -> the removed member specifically: tells them they've
  /// been kicked (their key was pulled off the allow-list while they were
  /// still a member), so their client removes the group locally.
  void sendGroupKicked(String targetKey, String groupId) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({'isGroupKicked': true, 'groupId': groupId});
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send kick notice: $e');
    }
  }

  void sendFriendRequest(String targetKey) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({'isFriendRequest': true});
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send friend request: $e');
    }
  }

  void sendFriendRequestReaction(String targetKey, bool didAccept) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({'didAcceptFRequest': didAccept});
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send friend-request reaction: $e');
    }
  }

  /// Tells [targetKey] that we've added or removed an [emoji] reaction on
  /// the message identified by [messageId]. Like read receipts and delete
  /// notices, this is signed and encrypted the same as any chat message -
  /// the relay only ever sees an opaque envelope, never which message or
  /// emoji is involved.
  void sendReactionUpdate(
    String targetKey,
    String messageId,
    String emoji,
    bool isAdd,
  ) {
    try {
      final recipient = RSAPublicKey.fromString(targetKey.trim());
      final plaintext = jsonEncode({
        'isReaction': true,
        'msgId': messageId,
        'emoji': emoji,
        'isAdd': isAdd,
      });
      final envelope = CryptoService.encryptEnvelope(
        plaintext: plaintext,
        recipientPublicKey: recipient,
        senderPrivateKey: privKey,
      );
      _send(
        Packet(
          type: PacketType.message,
          fromUser: myRawPublicKey,
          toUser: targetKey.trim(),
          payload: envelope,
        ),
      );
    } catch (e) {
      debugPrint('Failed to send reaction update: $e');
    }
  }

  /// Like [sendReactionUpdate], but fans the update out to every member of
  /// a group - same "no group packet on the wire" pattern as
  /// [sendGroupMessage] and [sendGroupDeleteNotice]. One member's copy
  /// failing doesn't stop delivery to the rest.
  ///
  /// Returns the raw public keys of any members delivery failed for
  /// (empty if everyone got it).
  Future<List<String>> sendGroupReactionUpdate({
    required List<String> memberKeys,
    required String groupId,
    required String messageId,
    required String emoji,
    required bool isAdd,
  }) async {
    final List<String> failedMembers = [];

    for (final memberKey in memberKeys) {
      try {
        final recipient = RSAPublicKey.fromString(memberKey.trim());
        final plaintext = jsonEncode({
          'isReaction': true,
          'isGroupMessage': true,
          'groupId': groupId,
          'msgId': messageId,
          'emoji': emoji,
          'isAdd': isAdd,
        });
        final envelope = CryptoService.encryptEnvelope(
          plaintext: plaintext,
          recipientPublicKey: recipient,
          senderPrivateKey: privKey,
        );
        _send(
          Packet(
            type: PacketType.message,
            fromUser: myRawPublicKey,
            toUser: memberKey.trim(),
            payload: envelope,
          ),
        );
      } catch (e) {
        debugPrint('Failed to deliver group reaction update to a member: $e');
        failedMembers.add(memberKey);
      }
    }

    return failedMembers;
  }

  Future<void> sendChatMessage({
    required String targetKey,
    required String text,
    required String msgId,
    required DateTime timestamp,
    String? replyToId,
    String? replyToText,
    String? replyToSenderKey,
    bool replyToIsMedia = false,
    String? replyToMediaType,
  }) async {
    final recipient = RSAPublicKey.fromString(targetKey.trim());
    final plaintext = jsonEncode({
      'isReceipt': false,
      'isFriendRequest': false,
      'text': text,
      'msgId': msgId,
      'timestamp': timestamp.toIso8601String(),
      if (replyToId != null) ...{
        'replyToId': replyToId,
        'replyToText': replyToText,
        'replyToSenderKey': replyToSenderKey,
        'replyToIsMedia': replyToIsMedia,
        'replyToMediaType': replyToMediaType,
      },
    });

    final envelope = CryptoService.encryptEnvelope(
      plaintext: plaintext,
      recipientPublicKey: recipient,
      senderPrivateKey: privKey,
    );

    _send(
      Packet(
        type: PacketType.message,
        fromUser: myRawPublicKey,
        toUser: targetKey.trim(),
        payload: envelope,
      ),
    );
  }

  /// Encrypts and sends a media attachment.
  ///
  /// Unlike a plain chat message, the media bytes themselves are never
  /// embedded in the WebSocket packet. Instead:
  ///  1. The raw bytes are encrypted with a fresh, single-use AES-256-GCM
  ///     key ([CryptoService.encryptMediaBytes]).
  ///  2. The ciphertext is streamed to the relay over HTTP POST
  ///     ([MediaService.uploadEncryptedMedia]), which hands back an opaque
  ///     media ID.
  ///  3. A small metadata packet - caption text, media ID, and the AES
  ///     key/IV - is signed and RSA-encrypted exactly like a normal chat
  ///     message and sent over the WebSocket.
  ///
  /// The relay still never sees plaintext, and the AES key is still only
  /// ever readable by the intended recipient (it's protected by the same
  /// envelope signature/encryption as any other message), but the bulk
  /// bytes no longer have to be base64-inflated and shoved through the
  /// same socket carrying live presence/read-receipt traffic.
  Future<void> sendMediaMessage({
    required String targetKey,
    required String msgId,
    required DateTime timestamp,
    required String text,
    required String mediaType,
    required String fileName,
    required Uint8List rawBytes,
    void Function(double progress)? onProgress,
    String? replyToId,
    String? replyToText,
    String? replyToSenderKey,
    bool replyToIsMedia = false,
    String? replyToMediaType,
  }) async {
    onProgress?.call(0.05);

    final material = await CryptoService.encryptMediaBytesInBackground(
      rawBytes,
    );

    onProgress?.call(0.35);

    final mediaId = await MediaService.uploadEncryptedMedia(
      serverIp: serverIp,
      ciphertext: material.ciphertext,
    );

    onProgress?.call(0.8);

    final plaintext = jsonEncode({
      'text': text,
      'msgId': msgId,
      'timestamp': timestamp.toIso8601String(),
      'mediaType': mediaType,
      'mediaFileName': fileName,
      'mediaId': mediaId,
      'mediaKey': material.keyBase64,
      'mediaIv': material.ivBase64,
      if (replyToId != null) ...{
        'replyToId': replyToId,
        'replyToText': replyToText,
        'replyToSenderKey': replyToSenderKey,
        'replyToIsMedia': replyToIsMedia,
        'replyToMediaType': replyToMediaType,
      },
    });

    final envelope = await CryptoService.encryptEnvelopeInBackground(
      plaintext: plaintext,
      recipientPublicKeyPem: targetKey.trim(),
      senderPrivateKeyPem: privKey.toString(),
    );

    onProgress?.call(0.9);

    _send(
      Packet(
        type: PacketType.message,
        fromUser: myRawPublicKey,
        toUser: targetKey.trim(),
        payload: envelope,
      ),
    );

    onProgress?.call(1.0);
  }

  /// Sends a text message to every member of a group.
  ///
  /// There is no such thing as a "group packet" on the wire - the relay
  /// has no concept of groups at all. This just calls the exact same
  /// sign-then-hybrid-encrypt path as a 1:1 message, once per member, each
  /// addressed individually and each carrying the same [groupId] and
  /// [msgId] in its plaintext so every recipient can file it under the
  /// same conversation. One member's copy failing to encrypt/send (e.g. a
  /// malformed key, or the socket dropping mid-loop) doesn't stop delivery
  /// to the rest.
  ///
  /// Returns the raw public keys of any members delivery failed for (empty
  /// if everyone got it), so the caller can decide how to surface partial
  /// failures instead of them being silently swallowed.
  Future<List<String>> sendGroupMessage({
    required List<String> memberKeys,
    required String groupId,
    required String text,
    required String msgId,
    required DateTime timestamp,
    String? replyToId,
    String? replyToText,
    String? replyToSenderKey,
    bool replyToIsMedia = false,
    String? replyToMediaType,
  }) async {
    final plaintext = jsonEncode({
      'isReceipt': false,
      'isFriendRequest': false,
      'isGroupMessage': true,
      'groupId': groupId,
      'text': text,
      'msgId': msgId,
      'timestamp': timestamp.toIso8601String(),
      if (replyToId != null) ...{
        'replyToId': replyToId,
        'replyToText': replyToText,
        'replyToSenderKey': replyToSenderKey,
        'replyToIsMedia': replyToIsMedia,
        'replyToMediaType': replyToMediaType,
      },
    });

    final List<String> failedMembers = [];

    for (final memberKey in memberKeys) {
      try {
        final recipient = RSAPublicKey.fromString(memberKey.trim());
        final envelope = CryptoService.encryptEnvelope(
          plaintext: plaintext,
          recipientPublicKey: recipient,
          senderPrivateKey: privKey,
        );
        _send(
          Packet(
            type: PacketType.message,
            fromUser: myRawPublicKey,
            toUser: memberKey.trim(),
            payload: envelope,
          ),
        );
      } catch (e) {
        debugPrint('Failed to deliver group message to a member: $e');
        failedMembers.add(memberKey);
      }
    }

    return failedMembers;
  }

  /// Sends a media attachment to every member of a group.
  ///
  /// The bytes are still only ever uploaded once - group members share
  /// the same ciphertext blob on the relay, exactly like a 1:1 attachment
  /// does. Only the small metadata packet (caption, media ID, AES key/IV)
  /// is repeated, once per member, the same way [sendGroupMessage] repeats
  /// a text message.
  ///
  /// Returns the raw public keys of any members delivery failed for (empty
  /// if everyone got it). The upload itself (which happens once, before
  /// any per-member packet goes out) is NOT covered by this - a failure
  /// there throws directly, since without it nobody could receive the
  /// attachment at all.
  Future<List<String>> sendGroupMediaMessage({
    required List<String> memberKeys,
    required String groupId,
    required String msgId,
    required DateTime timestamp,
    required String text,
    required String mediaType,
    required String fileName,
    required Uint8List rawBytes,
    void Function(double progress)? onProgress,
    String? replyToId,
    String? replyToText,
    String? replyToSenderKey,
    bool replyToIsMedia = false,
    String? replyToMediaType,
  }) async {
    onProgress?.call(0.05);

    final material = await CryptoService.encryptMediaBytesInBackground(
      rawBytes,
    );

    onProgress?.call(0.35);

    final mediaId = await MediaService.uploadEncryptedMedia(
      serverIp: serverIp,
      ciphertext: material.ciphertext,
    );

    onProgress?.call(0.7);

    final List<String> failedMembers = [];

    for (final memberKey in memberKeys) {
      try {
        final plaintext = jsonEncode({
          'isGroupMessage': true,
          'groupId': groupId,
          'text': text,
          'msgId': msgId,
          'timestamp': timestamp.toIso8601String(),
          'mediaType': mediaType,
          'mediaFileName': fileName,
          'mediaId': mediaId,
          'mediaKey': material.keyBase64,
          'mediaIv': material.ivBase64,
          if (replyToId != null) ...{
            'replyToId': replyToId,
            'replyToText': replyToText,
            'replyToSenderKey': replyToSenderKey,
            'replyToIsMedia': replyToIsMedia,
            'replyToMediaType': replyToMediaType,
          },
        });

        final envelope = await CryptoService.encryptEnvelopeInBackground(
          plaintext: plaintext,
          recipientPublicKeyPem: memberKey.trim(),
          senderPrivateKeyPem: privKey.toString(),
        );

        _send(
          Packet(
            type: PacketType.message,
            fromUser: myRawPublicKey,
            toUser: memberKey.trim(),
            payload: envelope,
          ),
        );
      } catch (e) {
        debugPrint('Failed to deliver group attachment to a member: $e');
        failedMembers.add(memberKey);
      }
    }

    onProgress?.call(1.0);
    return failedMembers;
  }

  /// Downloads and decrypts the media referenced by an already-decrypted
  /// message payload (as delivered via [onMessageReceived]). Callers
  /// should invoke this once, right after receiving a media message, or
  /// lazily if the user re-requests a download after the local cache was
  /// cleared.
  Future<Uint8List> fetchAndDecryptMedia({
    required String mediaId,
    required String mediaKeyBase64,
    required String mediaIvBase64,
  }) async {
    final ciphertext = await MediaService.downloadEncryptedMedia(
      serverIp: serverIp,
      mediaId: mediaId,
    );

    return CryptoService.decryptMediaBytesInBackground(
      ciphertext: ciphertext,
      keyBase64: mediaKeyBase64,
      ivBase64: mediaIvBase64,
    );
  }

  // --- incoming packets ----------------------------------------------------

  void _handleIncomingPacket(String rawData) {
    final Packet packet;
    try {
      packet = Packet.decode(rawData);
    } on MalformedPacketException catch (e) {
      // Untrusted input from the network; log and move on.
      debugPrint('Dropping malformed packet: $e');
      return;
    }

    switch (packet.type) {
      case PacketType.statusUpdate:
        _handleStatusUpdate(packet);
        return;
      case PacketType.message:
        _handleMessagePacket(packet);
        return;
      case PacketType.register:
        // The server never sends "register" packets back to clients; if
        // one arrives, it's either a protocol violation or a future
        // server feature we don't understand yet. Ignoring.
        return;
    }
  }

  void _handleStatusUpdate(Packet packet) {
    try {
      if (packet.fromUser == 'server') {
        final decoded = jsonDecode(packet.payload);
        if (decoded is! List) {
          debugPrint('Ignoring status_update: roster payload is not a list');
          return;
        }
        _onlinePeers
          ..clear()
          ..addAll(decoded.whereType<Object>().map((e) => e.toString().trim()));
      } else {
        final status = packet.payload;
        if (status == 'online') {
          _onlinePeers.add(packet.fromUser);
        } else {
          _onlinePeers.remove(packet.fromUser);
        }
      }
      onStatusUpdateReceived(_onlinePeers);
    } catch (e) {
      debugPrint('Failed to process status_update: $e');
    }
  }

  void _handleMessagePacket(Packet packet) {
    final String plaintext;
    try {
      final claimedSender = RSAPublicKey.fromString(packet.fromUser);
      plaintext = CryptoService.decryptEnvelope(
        rawEnvelope: packet.payload,
        myPrivateKey: privKey,
        expectedSenderPublicKey: claimedSender,
      );
    } on EnvelopeAuthException catch (e) {
      // Either it's not addressed to us, it's corrupted/tampered, or the
      // signature doesn't match the claimed sender. drop silently in either case.
      debugPrint('Dropping unverifiable packet: $e');
      return;
    } catch (e) {
      debugPrint('Dropping packet with unparseable sender identity: $e');
      return;
    }

    final Map<String, dynamic> payloadMap;
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('decrypted payload is not a JSON object');
      }
      payloadMap = decoded;
    } catch (e) {
      debugPrint('Dropping packet with malformed decrypted payload: $e');
      return;
    }

    if (payloadMap['isGroupJoinRequest'] == true) {
      final groupId = payloadMap['groupId'];
      final secret = payloadMap['secret'];
      if (groupId is String && secret is String) {
        onGroupJoinRequestReceived(packet.fromUser, groupId, secret);
      }
      return;
    }

    if (payloadMap['isGroupJoinAccepted'] == true) {
      final groupId = payloadMap['groupId'];
      final groupName = payloadMap['groupName'];
      final memberKeys = payloadMap['memberKeys'];
      final allowedJoinerKeys = payloadMap['allowedJoinerKeys'];
      if (groupId is String &&
          groupName is String &&
          memberKeys is List &&
          allowedJoinerKeys is List) {
        onGroupJoinAccepted(
          groupId,
          memberKeys.whereType<String>().toList(),
          groupName,
          allowedJoinerKeys.whereType<String>().toList(),
        );
      }
      return;
    }

    if (payloadMap['isGroupJoinRejected'] == true) {
      final groupId = payloadMap['groupId'];
      if (groupId is String) {
        onGroupJoinRejected(groupId);
      }
      return;
    }

    if (payloadMap['isGroupMemberAdded'] == true) {
      final groupId = payloadMap['groupId'];
      final newMemberKey = payloadMap['newMemberKey'];
      if (groupId is String && newMemberKey is String) {
        onGroupMemberAdded(groupId, newMemberKey);
      }
      return;
    }

    if (payloadMap['isGroupAllowListChangeRequest'] == true) {
      final groupId = payloadMap['groupId'];
      final addKeys = payloadMap['addKeys'];
      final removeKeys = payloadMap['removeKeys'];
      if (groupId is String && addKeys is List && removeKeys is List) {
        onGroupAllowListChangeRequestReceived(
          packet.fromUser,
          groupId,
          addKeys.whereType<String>().toList(),
          removeKeys.whereType<String>().toList(),
        );
      }
      return;
    }

    if (payloadMap['isGroupAllowListSync'] == true) {
      final groupId = payloadMap['groupId'];
      final allowedJoinerKeys = payloadMap['allowedJoinerKeys'];
      final removedMemberKeys = payloadMap['removedMemberKeys'];
      if (groupId is String &&
          allowedJoinerKeys is List &&
          removedMemberKeys is List) {
        onGroupAllowListSyncReceived(
          groupId,
          allowedJoinerKeys.whereType<String>().toList(),
          removedMemberKeys.whereType<String>().toList(),
        );
      }
      return;
    }

    if (payloadMap['isGroupKicked'] == true) {
      final groupId = payloadMap['groupId'];
      if (groupId is String) {
        onGroupKicked(groupId);
      }
      return;
    }

    // Group text/media messages, deletes, edits, receipts, and reactions
    // all set `isGroupMessage: true` - a plain chat message routes to
    // [onGroupMessageReceived], while a delete/edit/receipt/reaction that
    // also carries `groupId` routes to its group-scoped counterpart
    // instead of the 1:1 one below. Checked in this order so a group
    // delete/edit/receipt/reaction (which also sets
    // `isDelete`/`isEdit`/`isReceipt`/`isReaction`) doesn't fall through
    // to the 1:1 handlers.
    if (payloadMap['isGroupMessage'] == true) {
      final groupId = payloadMap['groupId'];
      if (groupId is! String) return;

      if (payloadMap['isDelete'] == true) {
        final msgId = payloadMap['msgId'];
        if (msgId is String) {
          onGroupMessageDeleted(packet.fromUser, groupId, msgId);
        }
        return;
      }

      if (payloadMap['isReceipt'] == true) {
        final msgId = payloadMap['msgId'];
        if (msgId is String) {
          onGroupReadReceiptReceived(packet.fromUser, groupId, msgId);
        }
        return;
      }

      if (payloadMap['isReaction'] == true) {
        final msgId = payloadMap['msgId'];
        final emoji = payloadMap['emoji'];
        final isAdd = payloadMap['isAdd'];
        if (msgId is String && emoji is String && isAdd is bool) {
          onGroupReactionReceived(packet.fromUser, groupId, msgId, emoji, isAdd);
        }
        return;
      }

      if (payloadMap['isEdit'] == true) {
        final msgId = payloadMap['msgId'];
        final newText = payloadMap['text'];
        if (msgId is String && newText is String) {
          onGroupMessageEdited(packet.fromUser, groupId, msgId, newText);
        }
        return;
      }

      onGroupMessageReceived(
        packet.fromUser,
        groupId,
        (payloadMap['text'] as String?) ?? '',
        payloadMap,
      );
      return;
    }

    if (payloadMap['isDelete'] == true) {
      final msgId = payloadMap['msgId'];
      if (msgId is String) {
        onMessageDeleted(packet.fromUser, msgId);
      }
      return;
    }

    if (payloadMap['isReceipt'] == true) {
      final msgId = payloadMap['msgId'];
      if (msgId is String) {
        onReadReceiptReceived(packet.fromUser, msgId);
      }
      return;
    }

    if (payloadMap['isReaction'] == true) {
      final msgId = payloadMap['msgId'];
      final emoji = payloadMap['emoji'];
      final isAdd = payloadMap['isAdd'];
      if (msgId is String && emoji is String && isAdd is bool) {
        onReactionReceived(packet.fromUser, msgId, emoji, isAdd);
      }
      return;
    }

    if (payloadMap['isEdit'] == true) {
      final msgId = payloadMap['msgId'];
      final newText = payloadMap['text'];
      if (msgId is String && newText is String) {
        onMessageEdited(packet.fromUser, msgId, newText);
      }
      return;
    }

    if (payloadMap['isFriendRequest'] == true) {
      onFriendRequestReceived(packet.fromUser);
      return;
    }

    if (payloadMap['didAcceptFRequest'] == true) {
      onFriendRequestAccepted(packet.fromUser);
      return;
    }

    onMessageReceived(
      packet.fromUser,
      (payloadMap['text'] as String?) ?? '',
      payloadMap,
    );
  }
}
