import 'dart:async';
import 'dart:ui';

import 'package:crypton/crypton.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';

import 'chat_session_manager.dart';
import 'mention_utils.dart';
import 'notification_service.dart';
import 'storage_service.dart';

/// Keeps Morse Messenger's relay connection alive on Android after the app
/// is backgrounded or the UI isolate is killed by the OS, by running a
/// second, independent connection inside an Android foreground service.
///
/// This does NOT replace the connection [ChatSessionManager] holds inside
/// the running UI - the two are separate instances that never touch the
/// same socket. When the UI is in front, both may briefly be connected at
/// once; that's harmless; the relay just delivers to whichever socket asks,
/// and both sides land in the same encrypted-history storage keyed by
/// message ID, so duplicates are naturally deduplicated on next read.
///
/// The service intentionally only replicates enough of the UI's receive
/// path to (a) not lose incoming messages and (b) raise a notification for
/// them. Things that only make sense with a visible UI - live typing
/// state, marking things read because a chat happens to be open, reacting,
/// deleting, group-membership admin flows - are left to the foreground app
/// to reconcile the next time it's opened and reconnects; the messages
/// themselves are persisted here so nothing is lost in the meantime.
class BackgroundService {
  BackgroundService._();

  static const String _notificationChannelId = 'morse_background_service';
  static const int _serviceNotificationId = 777;

  /// Registers and starts the Android foreground service. Safe to call
  /// every app launch - `autoStart` plus the OS's own "restart my foreground
  /// service" behavior means this is idempotent in practice.
  static Future<void> initialize() async {
    if (kIsWeb) return;

    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: true,
        isForegroundMode: true,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'Morse Messenger',
        initialNotificationContent: 'Staying connected in the background',
        foregroundServiceNotificationId: _serviceNotificationId,
      ),
      // iOS doesn't allow arbitrary long-running background sockets the
      // way Android's foreground-service model does, so this is
      // deliberately Android-only - iosConfiguration is left at its
      // defaults (the service package no-ops there).
      iosConfiguration: IosConfiguration(),
    );

    await service.startService();
  }

  /// Entry point for the background isolate. Must stay a static/top-level
  /// function annotated with `vm:entry-point`, or the Android service host
  /// won't be able to find it after the engine restarts headlessly.
  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
    }

    // This isolate never touched the UI isolate's Hive boxes - open them
    // fresh here.
    try {
      await StorageService.initDatabase();
    } catch (e) {
      debugPrint('BackgroundService: storage init failed ($e); stopping.');
      service.stopSelf();
      return;
    }

    try {
      await NotificationService.initialize();
    } catch (e) {
      debugPrint('BackgroundService: notification init failed: $e');
    }

    final savedKeyPem = await StorageService.readPrivateKey();
    final serverIp = await StorageService.fetchServerIp();
    if (savedKeyPem == null || serverIp == null || serverIp.trim().isEmpty) {
      // Nothing configured yet (e.g. very first launch, before the user has
      // connected to a server) - nothing for this service to do.
      debugPrint('BackgroundService: no identity/server configured; stopping.');
      service.stopSelf();
      return;
    }

    final RSAPrivateKey privKey;
    final String myRawPublicKey;
    try {
      final kp = RSAKeypair(RSAPrivateKey.fromString(savedKeyPem));
      privKey = kp.privateKey;
      myRawPublicKey = kp.publicKey.toString().trim();
    } catch (e) {
      debugPrint('BackgroundService: failed to load identity ($e); stopping.');
      service.stopSelf();
      return;
    }

    // Local mirror of the contact/group nickname indexes, refreshed
    // whenever something arrives that could change them. Kept in plain
    // maps rather than reusing the app's ChatPeer/model classes, since all
    // this needs is "what do I call this key in a notification".
    Map<String, String> peerNicknames = {};
    Map<String, Set<String>> groupMembers = {};
    Map<String, String> groupNames = {};

    Future<void> reloadContacts() async {
      final peers = await StorageService.fetchPeerList();
      final groups = await StorageService.fetchGroupList();

      peerNicknames = {
        for (final p in peers)
          if (p['publicKey'] != null) p['publicKey']!: p['nickname'] ?? '',
      };
      groupMembers = {
        for (final g in groups)
          if (g['id'] is String)
            g['id'] as String:
                ((g['members'] as List?) ?? const []).cast<String>().toSet(),
      };
      groupNames = {
        for (final g in groups)
          if (g['id'] is String) g['id'] as String: (g['name'] as String?) ?? 'Group chat',
      };
    }

    await reloadContacts();

    String displayNameFor(String rawPublicKey) {
      if (rawPublicKey == myRawPublicKey) return 'You';
      final saved = peerNicknames[rawPublicKey];
      if (saved != null && saved.isNotEmpty) return saved;
      final trimmed = rawPublicKey.trim();
      return trimmed.length > 15 ? trimmed.substring(trimmed.length - 15) : trimmed;
    }

    String mediaFallbackLabel(String? mediaType) {
      switch (mediaType) {
        case 'image':
          return '📷 Photo';
        case 'video':
          return '🎥 Video';
        case 'audio':
          return '🎤 Voice message';
        default:
          return '📎 Attachment';
      }
    }

    int notificationSeq = 0;
    void notify({required String title, required String body}) {
      NotificationService.showNotification(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000 + (notificationSeq++),
        title: title,
        body: body,
      );
    }

    Future<void> persistIncoming({
      required String conversationKey,
      required String senderKey,
      required String text,
      required Map<String, dynamic> payload,
    }) {
      return StorageService.persistEncryptedMessage(
        peerPublicKey: conversationKey,
        msgId: (payload['msgId'] as String?) ??
            '${DateTime.now().millisecondsSinceEpoch}',
        encryptedPayload: text,
        isMe: false,
        isRead: false,
        timestampIso:
            DateTime.tryParse(payload['timestamp'] as String? ?? '')
                    ?.toIso8601String() ??
                DateTime.now().toIso8601String(),
        mediaType: payload['mediaType'] as String?,
        mediaFileName: payload['mediaFileName'] as String?,
        mediaId: payload['mediaId'] as String?,
        mediaKeyBase64: payload['mediaKey'] as String?,
        mediaIvBase64: payload['mediaIv'] as String?,
        senderKey: senderKey,
        replyToId: payload['replyToId'] as String?,
        replyToText: payload['replyToText'] as String?,
        replyToSenderKey: payload['replyToSenderKey'] as String?,
        replyToIsMedia: payload['replyToIsMedia'] == true,
        replyToMediaType: payload['replyToMediaType'] as String?,
      );
    }

    late final ChatSessionManager session;
    session = ChatSessionManager(
      serverIp: serverIp,
      myRawPublicKey: myRawPublicKey,
      privKey: privKey,
      onStateChanged: () {},
      onFriendRequestReceived: (senderKey) {
        notify(
          title: 'New chat request',
          body: '${displayNameFor(senderKey)} wants to connect.',
        );
      },
      onFriendRequestAccepted: (senderKey) async {
        await reloadContacts();
        notify(
          title: 'Request accepted',
          body: '${displayNameFor(senderKey)} accepted your chat request.',
        );
      },
      onMessageReceived: (senderKey, text, payload) async {
        final cleanedSenderKey = senderKey.trim();
        // Mirrors the UI's own rule: only notify for someone already an
        // accepted contact, never an unsolicited stranger.
        if (!peerNicknames.containsKey(cleanedSenderKey)) return;

        await persistIncoming(
          conversationKey: cleanedSenderKey,
          senderKey: cleanedSenderKey,
          text: text,
          payload: payload,
        );

        final mediaType = payload['mediaType'] as String?;
        notify(
          title: displayNameFor(cleanedSenderKey),
          body: mediaType != null
              ? mediaFallbackLabel(mediaType)
              : MentionUtils.stripMentionsToPlainText(text, displayNameFor),
        );
      },
      onGroupMessageReceived: (senderKey, groupId, text, payload) async {
        final cleanedSenderKey = senderKey.trim();
        final members = groupMembers[groupId];
        // Mirrors the UI's own rule: group must be known locally and the
        // sender must actually be a member of it.
        if (members == null || !members.contains(cleanedSenderKey)) return;

        await persistIncoming(
          conversationKey: groupId,
          senderKey: cleanedSenderKey,
          text: text,
          payload: payload,
        );

        final mentionsMe = MentionUtils.mentionsEveryone(text) ||
            MentionUtils.extractMentionedKeys(text).contains(myRawPublicKey);
        final groupName = groupNames[groupId] ?? 'Group chat';
        final mediaType = payload['mediaType'] as String?;

        notify(
          title: mentionsMe
              ? '${displayNameFor(cleanedSenderKey)} mentioned you in $groupName'
              : groupName,
          body: mediaType != null
              ? mediaFallbackLabel(mediaType)
              : MentionUtils.stripMentionsToPlainText(text, displayNameFor),
        );
      },
      onGroupJoinAccepted: (_, __, ___, ____) => reloadContacts(),
      onGroupMemberAdded: (_, __) => reloadContacts(),
      onGroupAllowListSyncReceived: (_, __, ___) => reloadContacts(),
      // Everything below only matters for state the visible UI reconciles
      // (read state, reactions, deletes, join-request admin, kicks) - safe
      // to leave as no-ops here since the app re-syncs on next foreground
      // connect, and none of it should raise a notification on its own.
      onReadReceiptReceived: (_, __) {},
      onStatusUpdateReceived: (_) {},
      onMessageDeleted: (_, __) {},
      onReactionReceived: (_, __, ___, ____) {},
      onGroupReadReceiptReceived: (_, __, ___) {},
      onGroupReactionReceived: (_, __, ___, ____, _____) {},
      onGroupMessageDeleted: (_, __, ___) {},
      onGroupJoinRequestReceived: (_, __, ___) {},
      onGroupJoinRejected: (_) {},
      onGroupAllowListChangeRequestReceived: (_, __, ___, ____) {},
      onGroupKicked: (_) {},
    );

    session.initializeWebSocket();

    // No widget tree is around to drive reconnects here, so nudge it
    // ourselves on a timer - mirrors the reconnect guarantee the UI gets
    // for free from its own lifecycle callbacks.
    final reconnectTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!session.isServerConnected && !session.isConnecting) {
        session.initializeWebSocket();
      }
    });

    service.on('stopService').listen((event) {
      reconnectTimer.cancel();
      session.dispose();
      service.stopSelf();
    });
  }
}