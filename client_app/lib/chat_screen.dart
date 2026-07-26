import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:client_app/notification_service.dart';
import 'package:client_app/rounded_divider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypton/crypton.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'audio_player_widget.dart';
import 'image_preview_widget.dart';
import 'models.dart';
import 'dialogs.dart';
import 'storage_service.dart';
import 'connection_setup_screen.dart';
import 'expanded_sidebar.dart';
import 'compact_sidebar.dart';
import 'chat_session_manager.dart';
import 'video_player_widget.dart';
import 'swipe_to_reply.dart';

class DecentralizedChat extends StatefulWidget {
  const DecentralizedChat({super.key});

  @override
  State<DecentralizedChat> createState() => _DecentralizedChatState();
}

class _DecentralizedChatState extends State<DecentralizedChat>
    with WidgetsBindingObserver {
  ChatSessionManager? _sessionManager;

  bool _isWindowInFocus = true;

  final _msgController = TextEditingController();
  final _keyInputController = TextEditingController();
  final _nameController = TextEditingController();
  final _ipController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _msgFocusNode = FocusNode();

  final List<ChatPeer> _peers = [];
  // Groups are just [ChatPeer]s with `isGroup: true`: same messages list,
  // same storage functions, same selection/rendering code. Kept in their
  // own list only so the sidebar can be handed "peers and groups"
  // separately from "peers I might friend-request".
  final List<ChatPeer> _groups = [];
  ChatPeer? _selectedPeer;

  /// What the sidebars actually render: every 1:1 contact plus every
  /// group, side by side. Both sidebar widgets already work purely in
  /// terms of [ChatPeer] (nickname, shortId, messages, online status), so
  /// groups slot in without either sidebar needing to know groups exist.
  List<ChatPeer> get _sidebarEntries => [..._peers, ..._groups];
  late RSAPrivateKey _privKey;

  String _serverIp = "localhost:8080";
  String _myRawPublicKey = "";
  String _myShortId = "";
  bool _autoScroll = true;
  bool _isMobileSidebarExpanded = false;
  bool _isMessageEmpty = true;

  /// True while a system UI (file picker, share sheet, etc.) is up on top
  /// of us. Android reports that as us being "paused" just like real
  /// backgrounding, so we use this to tell the two apart and avoid
  /// dropping the relay connection for something the user didn't actually
  /// leave the app for.
  bool _isPickingFile = false;

  /// Delays the actual disconnect after the app is backgrounded on mobile,
  /// instead of dropping the connection the instant `paused` fires. A
  /// short interruption (file picker, share sheet, a permission dialog,
  /// quickly checking another app) resolves before this timer goes off,
  /// so the socket - and any in-flight send - survives it. Only a
  /// genuinely prolonged backgrounding results in a real disconnect.
  Timer? _backgroundDisconnectTimer;
  static const Duration _backgroundGracePeriod = Duration(seconds: 25);

  Set<String> _onlinePeers = {};

  /// The message currently staged as a reply target, shown as a small
  /// preview above the input field. Cleared once the reply is sent or the
  /// user cancels it.
  ChatMessage? _replyingTo;

  /// GlobalKeys for every currently-rendered message bubble, created
  /// lazily as each bubble builds. Lets tapping a quoted-reply block
  /// scroll the original message into view via [Scrollable.ensureVisible]
  /// without needing a lazy ListView.builder + index math.
  final Map<String, GlobalKey> _messageBubbleKeys = {};

  /// The id of the message currently flashing a highlight after being
  /// jumped to from a reply quote, or null if nothing's highlighted.
  String? _highlightedMessageId;
  Timer? _highlightClearTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ipController.text = _serverIp;
    _loadOrCreateIdentity();

    _msgController.addListener(() {
      final isEmpty = _msgController.text.trim().isEmpty;
      if (_isMessageEmpty != isEmpty) {
        setState(() {
          _isMessageEmpty = isEmpty;
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backgroundDisconnectTimer?.cancel();
    _highlightClearTimer?.cancel();
    _sessionManager?.disconnect();
    _msgFocusNode.dispose();
    _scrollController.dispose();
    _msgController.dispose();
    _keyInputController.dispose();
    _nameController.dispose();
    _ipController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;

    setState(() {
      _isWindowInFocus = state == AppLifecycleState.resumed;
    });

    // Determine if the current platform is a mobile device
    final bool isMobile = Platform.isAndroid || Platform.isIOS;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // ONLY force disconnect on mobile platforms when minimized/suspended
      if (isMobile) {
        // A file picker, share sheet, or similar system UI also reports
        // as "paused" - don't tear the connection down for that, or any
        // send already in flight (e.g. a media upload) fails the instant
        // the picker opens.
        if (_isPickingFile) {
          debugPrint("Backgrounded for a system picker - keeping the connection alive.");
          return;
        }
        debugPrint(
          "Mobile backgrounding detected: keeping the connection alive for "
          "${_backgroundGracePeriod.inSeconds}s in case this is brief.",
        );
        _backgroundDisconnectTimer?.cancel();
        _backgroundDisconnectTimer = Timer(_backgroundGracePeriod, () {
          debugPrint("Still backgrounded after the grace period: securing session pipeline.");
          _sessionManager?.disconnect();
        });
      }
    } else if (state == AppLifecycleState.resumed) {
      // We're back - cancel any pending disconnect from a backgrounding
      // that turned out to be brief, and reconnect if the grace period
      // already expired (or we were never connected to begin with).
      _backgroundDisconnectTimer?.cancel();
      _backgroundDisconnectTimer = null;

      if (isMobile && !(_sessionManager?.isServerConnected ?? false)) {
        _startSession();
      }

      if (_selectedPeer != null) {
        _checkAndSendPendingReceipts();
      }
    }
  }

  void _loadOrCreateIdentity() async {
    String? savedKeyPem = await StorageService.readPrivateKey();
    RSAKeypair kp;

    if (savedKeyPem != null) {
      kp = RSAKeypair(RSAPrivateKey.fromString(savedKeyPem));
    } else {
      kp = RSAKeypair.fromRandom();
      await StorageService.savePrivateKey(kp.privateKey.toString());
    }

    final savedPeers = await StorageService.fetchPeerList();
    final List<ChatPeer> hydratedPeers = savedPeers.map((data) {
      return ChatPeer(
        rawPublicKey: data['publicKey']!,
        nickname: data['nickname']!,
      );
    }).toList();

    final savedGroups = await StorageService.fetchGroupList();
    final List<ChatPeer> hydratedGroups = savedGroups.map((data) {
      return ChatPeer(
        rawPublicKey: data['id'] as String,
        nickname: data['name'] as String,
        isGroup: true,
        isPending: data['isPending'] == true,
        groupMemberKeys: ((data['members'] as List?) ?? const [])
            .cast<String>(),
        allowedJoinerKeys: ((data['allowedJoinerKeys'] as List?) ?? const [])
            .cast<String>(),
        groupInviteSecret: data['inviteSecret'] as String?,
        groupIntroducerKey: data['introducerKey'] as String?,
      );
    }).toList();

    final String? savedIp = await StorageService.fetchServerIp();

    if (!mounted) return;
    setState(() {
      _privKey = kp.privateKey;
      _myRawPublicKey = kp.publicKey.toString().trim();
      _myShortId = _myRawPublicKey.substring(_myRawPublicKey.length - 15);
      _peers.addAll(hydratedPeers);
      _groups.addAll(hydratedGroups);

      if (savedIp != null && savedIp.isNotEmpty) {
        _serverIp = savedIp;
        _ipController.text = savedIp;
      }
    });

    _startSession();
  }

  void _startSession() {
    // Tear down any previous connection first
    _sessionManager?.disconnect();

    _sessionManager = ChatSessionManager(
      serverIp: _serverIp,
      myRawPublicKey: _myRawPublicKey,
      privKey: _privKey,
      onStateChanged: () {
        if (mounted) {
          setState(() {});
          // If we just successfully connected/reconnected, flush receipts right away
          if (_sessionManager?.isServerConnected ?? false) {
            _checkAndSendPendingReceipts();
          }
        }
      },
      // ADD/RESTORE THIS PARAMETER ARGUMENT HERE:
      onStatusUpdateReceived: (updatedPeers) {
        if (mounted) {
          setState(() {
            _onlinePeers = updatedPeers;
          });
        }
      },
      onFriendRequestReceived: _processFriendRequest,
      onFriendRequestAccepted: (senderPublicKey) {
        if (!mounted) return;
        setState(() {
          final peerIndex = _peers.indexWhere(
            (p) => p.rawPublicKey.trim() == senderPublicKey,
          );
          if (peerIndex != -1) {
            _peers[peerIndex].isPending = false;
          }
        });
        _syncPeersToStorage();
      },
      onGroupReadReceiptReceived: _handleGroupReadReceipt,
      onGroupReactionReceived: _handleGroupReaction,
      onGroupMessageDeleted: _handleGroupMessageDeleted,
      onGroupJoinRequestReceived: _handleGroupJoinRequest,
      onGroupJoinAccepted: _handleGroupJoinAccepted,
      onGroupJoinRejected: _handleGroupJoinRejected,
      onGroupMemberAdded: _handleGroupMemberAdded,
      onGroupAllowListChangeRequestReceived: _handleGroupAllowListChangeRequest,
      onGroupAllowListSyncReceived: _handleGroupAllowListSync,
      onGroupKicked: _handleGroupKicked,
      onReadReceiptReceived: (senderPublicKey, targetMsgId) async {
        final cleanedSenderKey = senderPublicKey.trim();
        final peerIndex = _peers.indexWhere(
          (p) => p.rawPublicKey.trim() == cleanedSenderKey,
        );
        if (peerIndex == -1) return;

        final peer = _peers[peerIndex];
        final msgIndex = peer.messages.indexWhere((m) => m.id == targetMsgId);

        if (msgIndex != -1) {
          if (mounted) {
            setState(() {
              peer.messages[msgIndex].isRead = true;
            });
          }

          // Persist the read state to the database so it stays updated
          await StorageService.persistEncryptedMessage(
            peerPublicKey: cleanedSenderKey,
            msgId: targetMsgId,
            encryptedPayload: peer.messages[msgIndex].text,
            isMe: true,
            isRead: true,
            timestampIso: peer.messages[msgIndex].timestamp.toIso8601String(),
          );
        }
      },
      onMessageReceived: (senderKey, text, payload) async {
          final String? mediaType = payload['mediaType'];
          final String? mediaFileName = payload['mediaFileName'];
          final String? mediaId = payload['mediaId'];
          final String? mediaKeyBase64 = payload['mediaKey'];
          final String? mediaIvBase64 = payload['mediaIv'];

          final bool hasMedia = mediaType != null &&
              mediaId != null &&
              mediaKeyBase64 != null &&
              mediaIvBase64 != null;

          final String? replyToId = payload['replyToId'];
          final String? replyToText = payload['replyToText'];
          final String? replyToSenderKey = payload['replyToSenderKey'];
          final bool replyToIsMedia = payload['replyToIsMedia'] == true;
          final String? replyToMediaType = payload['replyToMediaType'];

          final incomingMsg = ChatMessage(
            text,
            false,
            customId: payload['msgId'],
            customTime: DateTime.tryParse(payload['timestamp'] ?? ''),
            mediaType: mediaType,
            mediaFileName: mediaFileName,
            mediaId: mediaId,
            mediaKeyBase64: mediaKeyBase64,
            mediaIvBase64: mediaIvBase64,
            isTransferring: hasMedia,
            replyToId: replyToId,
            replyToText: replyToText,
            replyToSenderKey: replyToSenderKey,
            replyToIsMedia: replyToIsMedia,
            replyToMediaType: replyToMediaType,
          );

          await _handleInboundMessageAppend(senderKey, incomingMsg);

          // Fetch + decrypt the attachment over HTTP now that the message
          // itself is visible, instead of the old approach where the
          // whole file had to already be sitting in the WebSocket packet
          // before the message could even show up.
          if (hasMedia) {
            _downloadAndCacheIncomingMedia(senderKey, incomingMsg);
          }
        },
      onReactionReceived: (senderKey, targetMsgId, emoji, isAdd) async {
        final cleanedSenderKey = senderKey.trim();
        final peerIndex = _peers.indexWhere(
          (p) => p.rawPublicKey.trim() == cleanedSenderKey,
        );
        if (peerIndex == -1) return;

        final peer = _peers[peerIndex];
        final msgIndex = peer.messages.indexWhere((m) => m.id == targetMsgId);
        if (msgIndex == -1) return;

        final message = peer.messages[msgIndex];

        if (mounted) {
          setState(() {
            _applyReactionChange(
              message: message,
              emoji: emoji,
              reactorKey: cleanedSenderKey,
              isAdd: isAdd,
            );
          });
        }

        await StorageService.persistEncryptedMessage(
          peerPublicKey: cleanedSenderKey,
          msgId: targetMsgId,
          encryptedPayload: message.text,
          isMe: message.isMe,
          timestampIso: message.timestamp.toIso8601String(),
          reactions: message.reactions,
        );
      },
      onGroupMessageReceived: (senderKey, groupId, text, payload) async {
        final cleanedSenderKey = senderKey.trim();
        final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
        if (groupIndex == -1) return; // not (or no longer) in this group

        final group = _groups[groupIndex];
        // Defense in depth: every envelope is already RSA-signed
        // end-to-end, so the sender can't be spoofed - but this also
        // rejects a message from someone who simply isn't a member of
        // this group (e.g. removed, or a stranger who learned the ID).
        if (!group.groupMemberKeys.contains(cleanedSenderKey)) return;

        final String? mediaType = payload['mediaType'];
        final String? mediaFileName = payload['mediaFileName'];
        final String? mediaId = payload['mediaId'];
        final String? mediaKeyBase64 = payload['mediaKey'];
        final String? mediaIvBase64 = payload['mediaIv'];
        final bool hasMedia = mediaType != null &&
            mediaId != null &&
            mediaKeyBase64 != null &&
            mediaIvBase64 != null;

        final String? replyToId = payload['replyToId'];
        final String? replyToText = payload['replyToText'];
        final String? replyToSenderKey = payload['replyToSenderKey'];
        final bool replyToIsMedia = payload['replyToIsMedia'] == true;
        final String? replyToMediaType = payload['replyToMediaType'];

        final incomingMsg = ChatMessage(
          text,
          false,
          customId: payload['msgId'],
          customTime: DateTime.tryParse(payload['timestamp'] ?? ''),
          senderKey: cleanedSenderKey,
          mediaType: mediaType,
          mediaFileName: mediaFileName,
          mediaId: mediaId,
          mediaKeyBase64: mediaKeyBase64,
          mediaIvBase64: mediaIvBase64,
          isTransferring: hasMedia,
          replyToId: replyToId,
          replyToText: replyToText,
          replyToSenderKey: replyToSenderKey,
          replyToIsMedia: replyToIsMedia,
          replyToMediaType: replyToMediaType,
        );

        if (group.messages.any((m) => m.id == incomingMsg.id)) return;

        final bool isChatOpenAndVisible =
            _selectedPeer == group && _isWindowInFocus && _autoScroll;

        await StorageService.persistEncryptedMessage(
          peerPublicKey: groupId,
          msgId: incomingMsg.id,
          encryptedPayload: text,
          isMe: false,
          isRead: isChatOpenAndVisible,
          timestampIso: incomingMsg.timestamp.toIso8601String(),
          mediaType: mediaType,
          mediaFileName: mediaFileName,
          mediaId: mediaId,
          mediaKeyBase64: mediaKeyBase64,
          mediaIvBase64: mediaIvBase64,
          senderKey: cleanedSenderKey,
          replyToId: replyToId,
          replyToText: replyToText,
          replyToSenderKey: replyToSenderKey,
          replyToIsMedia: replyToIsMedia,
          replyToMediaType: replyToMediaType,
        );

        if (!mounted) return;

        setState(() {
          incomingMsg.isRead = isChatOpenAndVisible;
          group.messages.add(incomingMsg);
        });

        if (!isChatOpenAndVisible) {
          NotificationService.showNotification(
            id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            title: group.nickname,
            body: text,
          );
        }

        if (isChatOpenAndVisible) {
          _sessionManager?.sendGroupReadReceipt(
            cleanedSenderKey,
            groupId,
            incomingMsg.id,
          );
        }

        _scrollToBottom();

        // Fetch + decrypt the shared attachment over HTTP, same as a 1:1
        // media message - the ciphertext was only ever uploaded once.
        if (hasMedia) {
          _downloadAndCacheIncomingMedia(groupId, incomingMsg);
        }
      },
      onMessageDeleted: (senderPublicKey, targetMsgId) {
        final cleanedSenderKey = senderPublicKey.trim();
        final peerIndex = _peers.indexWhere(
          (p) => p.rawPublicKey.trim() == cleanedSenderKey,
        );
        if (peerIndex == -1) return;

        final peer = _peers[peerIndex];
        final removedMsgIndex = peer.messages.indexWhere((m) => m.id == targetMsgId);
        if (removedMsgIndex == -1) return;

        // Only the message's original author may delete it for everyone -
        // otherwise this peer could delete a message *I* sent just by
        // sending a delete notice for its id. `isMe` means I authored it,
        // so a notice from the other side about it is never legitimate.
        if (peer.messages[removedMsgIndex].isMe) return;

        _deleteCachedMediaFile(peer.messages[removedMsgIndex]);
        if (mounted) {
          setState(() {
            peer.messages.removeWhere((m) => m.id == targetMsgId);
          });
        }
        StorageService.deleteMessage(
          peerPublicKey: cleanedSenderKey,
          msgId: targetMsgId,
        );
      },
    );

    _sessionManager!.initializeWebSocket();
  }

  /// Removes the locally cached copy of a media message's attachment, if
  /// any. Safe to call on text-only messages (no-op) or if the file is
  /// already gone.
  Future<void> _deleteCachedMediaFile(ChatMessage m) async {
    if (m.mediaType == null || m.localPath == null) return;
    try {
      final cachedFile = File(m.localPath!);
      if (await cachedFile.exists()) {
        await cachedFile.delete();
      }
    } catch (e) {
      debugPrint('Failed to remove cached media file: $e');
    }
  }

  Future<void> _pickAndSendMedia() async {
    if (_selectedPeer == null || _sessionManager == null) return;
    if (_selectedPeer!.isGroup && _selectedPeer!.isPending) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Still waiting for approval to join this group.'),
        ),
      );
      return;
    }

    FilePickerResult? result;
    setState(() => _isPickingFile = true);
    try {
      result = await FilePicker.platform.pickFiles(withData: false);
    } finally {
      // The picker returning is also roughly when Android reports us as
      // "resumed" again, but this flag matters for the split-second
      // window where didChangeAppLifecycleState's paused branch could
      // otherwise still see it as true.
      if (mounted) setState(() => _isPickingFile = false);
    }
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final String fileName = file.name;
    final String? filePath = file.path;

    if (filePath == null) return;

    String mediaType = 'document';
    final extension = file.extension?.toLowerCase();
    if (['png', 'jpg', 'jpeg', 'gif', 'webp'].contains(extension)) {
      mediaType = 'image';
    } else if (['mp3', 'wav', 'm4a', 'ogg'].contains(extension)) {
      mediaType = 'audio';
    } else if (['mp4', 'mov', 'avi', 'mkv'].contains(extension)) {
      mediaType = 'video';
    }

    final targetPeer = _selectedPeer!;
    final cleanedTargetKey = targetPeer.rawPublicKey.trim();
    final String msgId =
        "${DateTime.now().millisecondsSinceEpoch}-${targetPeer.rawPublicKey.substring(0, 5)}";
    final DateTime now = DateTime.now();

    // Send whatever caption the user already typed (if anything) alongside
    // the attachment, instead of a hardcoded placeholder string.
    final String caption = _msgController.text.trim();

    // Same snapshot-before-clearing approach as `_sendMessage` - captured
    // here (rather than after the tempMessage/setState below) so it can't
    // observe a reply the user cancelled mid-pick.
    final ChatMessage? replyingToSnapshot = _replyingTo;
    final String? replyToId = replyingToSnapshot?.id;
    final String? replyToText =
        replyingToSnapshot != null ? _replyPreviewText(replyingToSnapshot) : null;
    final String? replyToSenderKey = replyingToSnapshot != null
        ? _originalSenderKeyFor(replyingToSnapshot)
        : null;
    final bool replyToIsMedia = replyingToSnapshot?.isMedia ?? false;
    final String? replyToMediaType = replyingToSnapshot?.mediaType;

    final tempMessage = ChatMessage(
      caption,
      true,
      customTime: now,
      customId: msgId,
      mediaType: mediaType,
      mediaFileName: fileName,
      localPath: filePath,
      isTransferring: true,
      uploadProgress: 0.05,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderKey: replyToSenderKey,
      replyToIsMedia: replyToIsMedia,
      replyToMediaType: replyToMediaType,
    );

    setState(() {
      targetPeer.messages.add(tempMessage);
      _replyingTo = null;
    });
    _msgController.clear();
    _scrollToBottom();

    final Uint8List fileBytes;
    try {
      fileBytes = await File(filePath).readAsBytes();
    } catch (e) {
      debugPrint('Failed to read picked file: $e');
      setState(() => targetPeer.messages.remove(tempMessage));
      return;
    }

    if (tempMessage.isCancelled) return;

    // Copy into our own permanent media cache. file_picker's returned
    // path can point at an OS-managed temp/cache location that gets
    // cleared out from under us (e.g. on low storage, or across app
    // restarts on some platforms), which is why sent attachments could
    // silently stop previewing after a while. Keeping our own copy
    // (same as we already do for received media) fixes that, and also
    // means a retry after a failed send doesn't depend on the picker's
    // temp file still existing.
    String persistentLocalPath = filePath;
    try {
      final cacheDir = await StorageService.getMediaCacheDirectory();
      final safeFileName = StorageService.sanitizeFileName(fileName);
      final cachedFile = File('${cacheDir.path}/${msgId}_$safeFileName');
      await cachedFile.writeAsBytes(fileBytes);
      persistentLocalPath = cachedFile.path;
      tempMessage.localPath = persistentLocalPath;
    } catch (e) {
      debugPrint('Failed to cache outgoing media locally, keeping picker path: $e');
    }

    if (tempMessage.isCancelled) return;

    await _deliverMediaMessage(
      tempMessage: tempMessage,
      targetPeer: targetPeer,
      cleanedTargetKey: cleanedTargetKey,
      msgId: msgId,
      now: now,
      caption: caption,
      mediaType: mediaType,
      fileName: fileName,
      fileBytes: fileBytes,
      persistentLocalPath: persistentLocalPath,
    );
  }

  /// Encrypts, uploads, and delivers the metadata packet(s) for an
  /// already-picked (and already locally-cached) attachment. Split out of
  /// [_pickAndSendMedia] so [_retrySendMedia] can re-run just this part
  /// without re-opening the file picker.
  Future<void> _deliverMediaMessage({
    required ChatMessage tempMessage,
    required ChatPeer targetPeer,
    required String cleanedTargetKey,
    required String msgId,
    required DateTime now,
    required String caption,
    required String mediaType,
    required String fileName,
    required Uint8List fileBytes,
    required String persistentLocalPath,
  }) async {
    void onUploadProgress(double progress) {
      if (tempMessage.isCancelled) {
        throw Exception('Upload cancelled by user.');
      }
      if (mounted) {
        setState(() {
          tempMessage.uploadProgress = progress;
        });
      }
    }

    try {
      // The app may still be mid-reconnect right after resuming (e.g. the
      // file picker's own delay pushed us past a brief backgrounding) -
      // wait it out instead of racing it and failing immediately.
      final bool connected = _sessionManager!.isServerConnected ||
          await _sessionManager!.waitUntilConnected();
      if (!connected) {
        throw const SocketException('No connection to the relay server');
      }

      List<String> failedMembers = const [];

      if (targetPeer.isGroup) {
        failedMembers = await _sessionManager!.sendGroupMediaMessage(
          memberKeys: targetPeer.groupMemberKeys,
          groupId: cleanedTargetKey,
          msgId: msgId,
          timestamp: now,
          text: caption,
          mediaType: mediaType,
          fileName: fileName,
          rawBytes: fileBytes,
          onProgress: onUploadProgress,
          replyToId: tempMessage.replyToId,
          replyToText: tempMessage.replyToText,
          replyToSenderKey: tempMessage.replyToSenderKey,
          replyToIsMedia: tempMessage.replyToIsMedia,
          replyToMediaType: tempMessage.replyToMediaType,
        );
        // Every member failing means nothing actually went out - treat it
        // as a full failure so it's retryable, rather than "delivered".
        if (targetPeer.groupMemberKeys.isNotEmpty &&
            failedMembers.length == targetPeer.groupMemberKeys.length) {
          throw const SocketException('No connection to the relay server');
        }
      } else {
        await _sessionManager!.sendMediaMessage(
          targetKey: cleanedTargetKey,
          msgId: msgId,
          timestamp: now,
          text: caption,
          mediaType: mediaType,
          fileName: fileName,
          rawBytes: fileBytes,
          onProgress: onUploadProgress,
          replyToId: tempMessage.replyToId,
          replyToText: tempMessage.replyToText,
          replyToSenderKey: tempMessage.replyToSenderKey,
          replyToIsMedia: tempMessage.replyToIsMedia,
          replyToMediaType: tempMessage.replyToMediaType,
        );
      }

      await StorageService.persistEncryptedMessage(
        peerPublicKey: cleanedTargetKey,
        msgId: msgId,
        isMe: true,
        encryptedPayload: caption,
        timestampIso: now.toIso8601String(),
        mediaType: mediaType,
        mediaFileName: fileName,
        localPath: persistentLocalPath,
        replyToId: tempMessage.replyToId,
        replyToText: tempMessage.replyToText,
        replyToSenderKey: tempMessage.replyToSenderKey,
        replyToIsMedia: tempMessage.replyToIsMedia,
        replyToMediaType: tempMessage.replyToMediaType,
      );

      if (!mounted) return;
      setState(() {
        tempMessage.isTransferring = false;
        tempMessage.sendFailed = false;
        tempMessage.uploadProgress = 1.0;
        tempMessage.localPath = persistentLocalPath;
      });

      if (failedMembers.isNotEmpty && mounted) {
        final int delivered = targetPeer.groupMemberKeys.length - failedMembers.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Delivered to $delivered of ${targetPeer.groupMemberKeys.length} '
              'group members - ${failedMembers.length} did not receive it.',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint("Failed to process media output pipeline: $e");
      if (!mounted) return;
      setState(() {
        tempMessage.isTransferring = false;
        tempMessage.uploadProgress = 0.0;
        if (tempMessage.isCancelled) {
          targetPeer.messages.remove(tempMessage);
        } else {
          tempMessage.sendFailed = true;
        }
      });

      if (!tempMessage.isCancelled) {
        final bool isConnectionIssue = e is SocketException || e is StateError;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isConnectionIssue
                  ? 'No connection to the relay server - the attachment was not sent. Tap it to retry.'
                  : 'Failed to deliver attachment: $e',
            ),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _retrySendMedia(tempMessage, targetPeer),
            ),
          ),
        );
      }
    }
  }

  /// User-triggered retry after [_deliverMediaMessage] failed. Re-reads
  /// the already-cached local copy rather than re-opening the file
  /// picker, so a failed group attachment (say, from a flaky connection)
  /// can just be resent as-is.
  void _retrySendMedia(ChatMessage m, ChatPeer targetPeer) async {
    if (_sessionManager == null) return;
    if (m.localPath == null || m.localPath!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Original file is no longer available.')),
      );
      return;
    }

    final cachedFile = File(m.localPath!);
    if (!await cachedFile.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Original file is no longer available.')),
      );
      return;
    }

    setState(() {
      m.sendFailed = false;
      m.isTransferring = true;
      m.uploadProgress = 0.05;
    });

    final Uint8List bytes = await cachedFile.readAsBytes();
    await _deliverMediaMessage(
      tempMessage: m,
      targetPeer: targetPeer,
      cleanedTargetKey: targetPeer.rawPublicKey.trim(),
      msgId: m.id,
      now: m.timestamp,
      caption: m.text,
      mediaType: m.mediaType ?? 'document',
      fileName: m.mediaFileName ?? 'file',
      fileBytes: bytes,
      persistentLocalPath: m.localPath!,
    );
  }

  void _processFriendRequest(String senderPublicKey) {
    bool peerExists = _peers.any(
      (p) => p.rawPublicKey.trim() == senderPublicKey,
    );
    if (peerExists) return;

    Dialogs.showUnknownPeerDialog(
      context: context,
      senderPublicKey: senderPublicKey,
      onAccept: (nickname) {
        if (!mounted) return;
        setState(() {
          final newPeer = ChatPeer(
            rawPublicKey: senderPublicKey,
            nickname: nickname,
          );
          _peers.add(newPeer);
          _selectedPeer ??= newPeer;
        });
        _syncPeersToStorage();
        _scrollToBottom();

        _sessionManager?.sendFriendRequestReaction(senderPublicKey, true);
      },
    );
  }

  /// Appends a freshly-decrypted, already-constructed inbound message
  /// ([incomingMsg]) to the right peer's chat, persists it (including any
  /// media metadata), and fires a read receipt or a notification depending
  /// on whether the chat is currently open and visible.
  ///
  /// This is the counterpart to the outbound `_pickAndSendMedia` /
  /// `_sendMessage` paths - it's what actually makes a message (text or
  /// media) show up for the recipient. [incomingMsg] already carries
  /// `mediaType` / `mediaFileName` / `mediaId` / `mediaKeyBase64` /
  /// `mediaIvBase64` (the attachment bytes themselves are fetched
  /// separately, right after this call, by
  /// `_downloadAndCacheIncomingMedia`), so unlike the old dead code this
  /// replaced, media messages are persisted with their metadata instead of
  /// degrading into a bare text bubble.
  Future<void> _handleInboundMessageAppend(
    String senderPublicKey,
    ChatMessage incomingMsg,
  ) async {
    final cleanedSenderKey = senderPublicKey.trim();
    final peerIndex = _peers.indexWhere(
      (p) => p.rawPublicKey.trim() == cleanedSenderKey,
    );
    // Unknown sender (no accepted friend request yet) - drop it, same as
    // the previous behavior.
    if (peerIndex == -1) return;

    final sender = _peers[peerIndex];
    if (sender.messages.any((m) => m.id == incomingMsg.id)) return;

    final bool isChatOpenAndVisible =
        _selectedPeer == sender && _isWindowInFocus && _autoScroll;

    await StorageService.persistEncryptedMessage(
      peerPublicKey: cleanedSenderKey,
      msgId: incomingMsg.id,
      encryptedPayload: incomingMsg.text,
      isMe: false,
      isRead: isChatOpenAndVisible,
      timestampIso: incomingMsg.timestamp.toIso8601String(),
      mediaType: incomingMsg.mediaType,
      mediaFileName: incomingMsg.mediaFileName,
      mediaId: incomingMsg.mediaId,
      mediaKeyBase64: incomingMsg.mediaKeyBase64,
      mediaIvBase64: incomingMsg.mediaIvBase64,
      localPath: incomingMsg.localPath,
      replyToId: incomingMsg.replyToId,
      replyToText: incomingMsg.replyToText,
      replyToSenderKey: incomingMsg.replyToSenderKey,
      replyToIsMedia: incomingMsg.replyToIsMedia,
      replyToMediaType: incomingMsg.replyToMediaType,
    );

    if (!mounted) return;

    setState(() {
      incomingMsg.isRead = isChatOpenAndVisible;
      sender.messages.add(incomingMsg);
    });

    if (isChatOpenAndVisible) {
      _sessionManager?.sendReadReceipt(cleanedSenderKey, incomingMsg.id);
    } else {
      NotificationService.showNotification(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: "New Message from ${sender.nickname}",
        body: incomingMsg.text,
      );
    }

    _scrollToBottom();
  }

  /// Downloads and decrypts [msg]'s attachment over HTTP, caches it to the
  /// local media sandbox, and updates both UI state and persisted history
  /// once done. Failures leave [ChatMessage.downloadFailed] set so the UI
  /// can offer a retry instead of the attachment silently never appearing.
  Future<void> _downloadAndCacheIncomingMedia(
    String peerPublicKey,
    ChatMessage msg,
  ) async {
    if (_sessionManager == null ||
        msg.mediaId == null ||
        msg.mediaKeyBase64 == null ||
        msg.mediaIvBase64 == null) {
      return;
    }

    final cleanedPeerKey = peerPublicKey.trim();

    try {
      final bytes = await _sessionManager!.fetchAndDecryptMedia(
        mediaId: msg.mediaId!,
        mediaKeyBase64: msg.mediaKeyBase64!,
        mediaIvBase64: msg.mediaIvBase64!,
      );

      final cacheDir = await StorageService.getMediaCacheDirectory();
      // mediaFileName came from the network (a remote peer's choice of
      // caption for their own file) - sanitize it before it ever touches a
      // file path, or a malicious peer could send something like
      // "../../../elsewhere" and write outside the cache directory.
      final safeFileName = StorageService.sanitizeFileName(msg.mediaFileName);
      final fileTarget = File('${cacheDir.path}/${msg.id}_$safeFileName');
      await fileTarget.writeAsBytes(bytes);

      if (mounted) {
        setState(() {
          msg.localPath = fileTarget.path;
          msg.isTransferring = false;
          msg.downloadFailed = false;
        });
      }

      await StorageService.persistEncryptedMessage(
        peerPublicKey: cleanedPeerKey,
        msgId: msg.id,
        isMe: false,
        encryptedPayload: msg.text,
        timestampIso: msg.timestamp.toIso8601String(),
        mediaType: msg.mediaType,
        mediaFileName: msg.mediaFileName,
        mediaId: msg.mediaId,
        mediaKeyBase64: msg.mediaKeyBase64,
        mediaIvBase64: msg.mediaIvBase64,
        localPath: fileTarget.path,
      );
    } catch (e) {
      debugPrint('Failed to download/decrypt incoming media: $e');
      if (mounted) {
        setState(() {
          msg.isTransferring = false;
          msg.downloadFailed = true;
        });
      }
    }
  }

  /// User-triggered retry after [_downloadAndCacheIncomingMedia] failed.
  void _retryDownload(ChatMessage m) {
    if (_selectedPeer == null) return;
    setState(() {
      m.downloadFailed = false;
      m.isTransferring = true;
    });
    _downloadAndCacheIncomingMedia(_selectedPeer!.rawPublicKey, m);
  }

  /// Returns the plaintext bytes for [m]'s attachment, preferring the
  /// local cache and falling back to an on-demand HTTP fetch + decrypt
  /// (e.g. the local cache was cleared, or this device never auto-fetched
  /// it in the first place).
  Future<Uint8List?> _resolveOrFetchMediaBytes(ChatMessage m) async {
    if (m.localPath != null && m.localPath!.isNotEmpty) {
      final cached = File(m.localPath!);
      if (await cached.exists()) {
        try {
          return await cached.readAsBytes();
        } catch (e) {
          debugPrint('Failed to read cached media file: $e');
        }
      }
    }

    if (_sessionManager != null &&
        m.mediaId != null &&
        m.mediaKeyBase64 != null &&
        m.mediaIvBase64 != null) {
      try {
        return await _sessionManager!.fetchAndDecryptMedia(
          mediaId: m.mediaId!,
          mediaKeyBase64: m.mediaKeyBase64!,
          mediaIvBase64: m.mediaIvBase64!,
        );
      } catch (e) {
        debugPrint('On-demand media fetch failed: $e');
      }
    }

    return null;
  }

  /// Saves a message's attachment (image, audio, video, or document) to
  /// the device's downloads location. Shared by every media type so
  /// "download" behaves identically everywhere it appears.
  Future<void> _saveAttachmentToDevice(ChatMessage m) async {
    final bytes = await _resolveOrFetchMediaBytes(m);
    if (!mounted) return;

    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load attachment for download.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    try {
      final savePath = await StorageService.saveBytesToDownloads(
        m.mediaFileName ?? 'attachment.dat',
        bytes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved to Downloads: $savePath'),
          backgroundColor: Theme.of(context).colorScheme.primary,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save media: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _checkAndSendPendingReceipts() {
    // Ensure we have a valid session and an active, non-system peer selected
    if (_selectedPeer == null || _sessionManager == null) return;
    if (!_sessionManager!.isServerConnected) {
      return; // Can't send if the socket is down!
    }
    if (_selectedPeer!.rawPublicKey == StorageService.savedMessagesPeerKey) {
      return;
    }
    // A pending group is one we've requested to join but haven't been
    // admitted to yet - there's no one to send a receipt to.
    if (_selectedPeer!.isGroup && _selectedPeer!.isPending) return;

    bool stateChanged = false;

    for (var m in _selectedPeer!.messages) {
      // If it's an incoming message and hasn't been marked read locally yet
      if (!m.isMe && !m.isRead) {
        if (_selectedPeer!.isGroup) {
          if (m.senderKey != null) {
            _sessionManager!.sendGroupReadReceipt(
              m.senderKey!,
              _selectedPeer!.rawPublicKey,
              m.id,
            );
          }
        } else {
          _sessionManager!.sendReadReceipt(_selectedPeer!.rawPublicKey, m.id);
        }
        m.isRead = true;
        stateChanged = true;

        // Update local database history so we don't try to send it again next time
        StorageService.persistEncryptedMessage(
          peerPublicKey: _selectedPeer!.rawPublicKey.trim(),
          msgId: m.id,
          encryptedPayload: m.text,
          isMe: false,
          isRead: true,
          timestampIso: m.timestamp.toIso8601String(),
        );
      }
    }

    if (stateChanged && mounted) {
      setState(() {});
    }
  }

  void _handleConnectNewPeer(String nickname, String key) {
    final String cleanedKey = key.trim();
    bool alreadyExists = _peers.any((p) => p.rawPublicKey.trim() == key);

    if (alreadyExists) {
      setState(() {
        _selectedPeer = _peers.firstWhere((p) => p.rawPublicKey.trim() == key);
      });
    } else {
      setState(() {
        final newPeer = ChatPeer(
          rawPublicKey: cleanedKey,
          nickname: nickname,
          isPending: true,
        );
        _peers.add(newPeer);
        _selectedPeer = newPeer;
      });
      _sessionManager?.sendFriendRequest(cleanedKey);
    }

    _keyInputController.clear();
    _nameController.clear();
  }

  /// A random, locally-generated 128-bit group ID (as hex). It's never
  /// sent anywhere on its own - it only ever travels wrapped inside an
  /// invite code the creator shares out-of-band - so the relay has no way
  /// to learn a group exists, let alone who's in it.
  String _generateGroupId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// A random, per-group secret that becomes part of the invite code (see
  /// [_buildInviteCode]). Unlike the group ID, this is never displayed or
  /// used to look anything up on its own - it only ever proves "I have a
  /// valid invite" to the group's introducer alongside the joiner's own
  /// (allow-listed) key.
  String _generateGroupSecret() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _buildInviteCode(ChatPeer group) {
    return base64Encode(
      utf8.encode(
        jsonEncode({
          'id': group.rawPublicKey,
          'secret': group.groupInviteSecret,
          'introducer': group.groupIntroducerKey,
        }),
      ),
    );
  }

  void _syncGroupsToStorage() async {
    final serialized = _groups
        .map(
          (g) => {
            'id': g.rawPublicKey,
            'name': g.nickname,
            'members': g.groupMemberKeys,
            'allowedJoinerKeys': g.allowedJoinerKeys,
            'inviteSecret': g.groupInviteSecret,
            'introducerKey': g.groupIntroducerKey,
            'isPending': g.isPending,
          },
        )
        .toList();
    await StorageService.saveGroupList(serialized);
  }

  /// Creates a new group locally, then shows the invite code that needs
  /// to be shared with everyone out-of-band so they can request to join
  /// via [_handleJoinGroup]. Nobody is contacted automatically - creating
  /// a group is a purely local action, same as generating your own
  /// identity key pair. Unlike the old scheme, [memberKeys] don't become
  /// members directly - they're seeded onto the group's allow-list, and
  /// still have to go through the same join-request handshake
  /// ([_handleGroupJoinRequest]) as anyone added later via group settings.
  /// You (the creator) are always the group's introducer - the one whose
  /// device actually evaluates join requests.
  void _handleCreateGroup(String groupName, List<String> memberKeys) {
    final groupId = _generateGroupId();
    final secret = _generateGroupSecret();
    final cleanedAllowed = {
      _myRawPublicKey,
      ...memberKeys.map((k) => k.trim()).where((k) => k.isNotEmpty),
    }.toList();

    late final ChatPeer newGroup;
    setState(() {
      newGroup = ChatPeer(
        rawPublicKey: groupId,
        nickname: groupName,
        isGroup: true,
        groupMemberKeys: [],
        allowedJoinerKeys: cleanedAllowed,
        groupInviteSecret: secret,
        groupIntroducerKey: _myRawPublicKey,
      );
      _groups.add(newGroup);
      _selectedPeer = newGroup;
    });
    _syncGroupsToStorage();

    Dialogs.showGroupInvite(
      context: context,
      inviteCode: _buildInviteCode(newGroup),
    );
  }

  /// Sends a join request for the group described by [inviteCode] - the
  /// actual admission decision happens asynchronously on the introducer's
  /// device (see [_handleGroupJoinRequest]), so the group is added locally
  /// in a pending state until [_handleGroupJoinAccepted] or
  /// [_handleGroupJoinRejected] resolves it. [groupName] is your own local
  /// name for it, same idea as nicknaming a new contact.
  void _handleJoinGroup(String groupName, String inviteCode) {
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(inviteCode.trim())));
      if (decoded is! Map ||
          decoded['id'] is! String ||
          decoded['secret'] is! String ||
          decoded['introducer'] is! String) {
        throw const FormatException('malformed invite code');
      }

      final groupId = decoded['id'] as String;
      final secret = decoded['secret'] as String;
      final introducerKey = (decoded['introducer'] as String).trim();

      if (_groups.any((g) => g.rawPublicKey == groupId)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You've already joined this group.")),
        );
        return;
      }

      setState(() {
        final newGroup = ChatPeer(
          rawPublicKey: groupId,
          nickname: groupName,
          isGroup: true,
          isPending: true,
          groupInviteSecret: secret,
          groupIntroducerKey: introducerKey,
        );
        _groups.add(newGroup);
        _selectedPeer = newGroup;
      });
      _syncGroupsToStorage();
      _sessionManager?.sendGroupJoinRequest(introducerKey, groupId, secret);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Join request sent - waiting for approval.'),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid invite code: $e')),
      );
    }
  }

  /// Runs on the group's introducer device when someone requests to join.
  /// Admits [requesterKey] only if both the invite secret matches AND
  /// their key is on the group's allow-list - either check failing is
  /// treated identically (silently not-allowed) to avoid leaking which one
  /// failed. [requesterKey] is already cryptographically authenticated by
  /// the time it reaches here (see [CryptoService.decryptEnvelope]), so
  /// this is purely an authorization check, not an authentication one.
  void _handleGroupJoinRequest(
    String requesterKey,
    String groupId,
    String secret,
  ) {
    final cleanedRequester = requesterKey.trim();
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    // Only the designated introducer evaluates join requests - anyone else
    // who happens to belong to the group ignores them.
    if (group.groupIntroducerKey != _myRawPublicKey) return;

    final bool secretMatches = group.groupInviteSecret == secret;
    final bool isAllowed = group.allowedJoinerKeys.contains(cleanedRequester);

    if (!secretMatches || !isAllowed) {
      _sessionManager?.sendGroupJoinRejected(cleanedRequester, groupId);
      return;
    }

    if (!group.groupMemberKeys.contains(cleanedRequester)) {
      setState(() {
        group.groupMemberKeys.add(cleanedRequester);
      });
      _syncGroupsToStorage();
    }

    final othersToNotify = group.groupMemberKeys
        .where((k) => k != cleanedRequester)
        .toList();

    _sessionManager?.sendGroupJoinAccepted(
      targetKey: cleanedRequester,
      groupId: groupId,
      memberKeys: [...othersToNotify, _myRawPublicKey],
      groupName: group.nickname,
      allowedJoinerKeys: group.allowedJoinerKeys,
    );

    // Tell every other existing member about the new joiner, so their
    // local roster grows to match - otherwise the new member's messages
    // would pass the introducer's own membership check but get silently
    // dropped by everyone else (see `onGroupMessageReceived`'s guard).
    if (othersToNotify.isNotEmpty) {
      _sessionManager?.sendGroupMemberAdded(
        othersToNotify,
        groupId,
        cleanedRequester,
      );
    }
  }

  void _handleGroupJoinAccepted(
    String groupId,
    List<String> memberKeys,
    String groupName,
    List<String> allowedJoinerKeys,
  ) {
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    setState(() {
      group.isPending = false;
      for (final key in memberKeys) {
        if (key != _myRawPublicKey && !group.groupMemberKeys.contains(key)) {
          group.groupMemberKeys.add(key);
        }
      }
      // The introducer is the sole source of truth for the allow-list -
      // adopt its copy outright rather than merging, so we start in sync
      // instead of with whatever (usually empty) local state we had while
      // pending.
      group.allowedJoinerKeys = List<String>.from(allowedJoinerKeys);
    });
    _syncGroupsToStorage();

    // The introducer already tells every other member about us
    // (`sendGroupMemberAdded`), but that's a single delivery per
    // recipient - if it's ever dropped, or simply arrives after
    // something we send, that member's `groupMemberKeys` would never
    // include us and would silently reject our messages/attachments for
    // good (see the membership check in `onGroupMessageReceived`).
    // Announcing ourselves directly to everyone we were just told about
    // closes that gap; every recipient already treats a repeat
    // "member added" for a key it already knows as a no-op, so this is
    // safe to send unconditionally.
    if (group.groupMemberKeys.isNotEmpty) {
      _sessionManager?.sendGroupMemberAdded(
        group.groupMemberKeys,
        groupId,
        _myRawPublicKey,
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Joined "$groupName"!')),
      );
    }
  }

  void _handleGroupJoinRejected(String groupId) {
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    setState(() {
      _groups.removeAt(groupIndex);
      if (_selectedPeer == group) _selectedPeer = null;
    });
    _syncGroupsToStorage();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Join request denied: your key is not on the allow-list.'),
        ),
      );
    }
  }

  void _handleGroupMemberAdded(String groupId, String newMemberKey) {
    final cleanedKey = newMemberKey.trim();
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    if (group.isPending || cleanedKey == _myRawPublicKey) return;
    if (group.groupMemberKeys.contains(cleanedKey)) return;

    setState(() {
      group.groupMemberKeys.add(cleanedKey);
    });
    _syncGroupsToStorage();
  }

  /// Runs on the introducer's device only - it alone owns the allow-list,
  /// which is what keeps every member's displayed copy from drifting apart
  /// (the previous peer-broadcast approach let members miss updates or
  /// join with stale/empty state). [requesterKey] must currently be a
  /// member (or the introducer itself); anyone else's request is ignored.
  void _handleGroupAllowListChangeRequest(
    String requesterKey,
    String groupId,
    List<String> addKeys,
    List<String> removeKeys,
  ) {
    final cleanedRequester = requesterKey.trim();
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    if (group.groupIntroducerKey != _myRawPublicKey) return;
    final bool requesterIsMember =
        group.groupMemberKeys.contains(cleanedRequester) ||
        cleanedRequester == _myRawPublicKey;
    if (!requesterIsMember) return;

    _applyAllowListChange(group, addKeys: addKeys, removeKeys: removeKeys);
  }

  /// Applies an allow-list add/remove on the introducer's authoritative
  /// copy, kicks anyone removed while still a member, and re-syncs every
  /// remaining member so nobody's local copy is left stale.
  void _applyAllowListChange(
    ChatPeer group, {
    required List<String> addKeys,
    required List<String> removeKeys,
  }) {
    final cleanedAdds = addKeys
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty && k != _myRawPublicKey);
    final cleanedRemoves = removeKeys
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toSet();

    final kickedKeys = cleanedRemoves
        .where((k) => group.groupMemberKeys.contains(k))
        .toList();

    setState(() {
      group.allowedJoinerKeys.addAll(
        cleanedAdds.where((k) => !group.allowedJoinerKeys.contains(k)),
      );
      group.allowedJoinerKeys.removeWhere((k) => cleanedRemoves.contains(k));
      group.groupMemberKeys.removeWhere((k) => kickedKeys.contains(k));
    });
    _syncGroupsToStorage();

    for (final kicked in kickedKeys) {
      _sessionManager?.sendGroupKicked(kicked, group.rawPublicKey);
    }
    if (group.groupMemberKeys.isNotEmpty) {
      _sessionManager?.sendGroupAllowListSync(
        group.groupMemberKeys,
        group.rawPublicKey,
        group.allowedJoinerKeys,
        kickedKeys,
      );
    }
  }

  /// Runs on every non-introducer member's device: adopts the
  /// introducer's authoritative allow-list outright (never merges) and
  /// drops any member who was just kicked from the local roster.
  void _handleGroupAllowListSync(
    String groupId,
    List<String> allowedJoinerKeys,
    List<String> removedMemberKeys,
  ) {
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    setState(() {
      group.allowedJoinerKeys = List<String>.from(allowedJoinerKeys);
      group.groupMemberKeys.removeWhere(
        (k) => removedMemberKeys.contains(k),
      );
    });
    _syncGroupsToStorage();
  }

  void _handleGroupKicked(String groupId) {
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    setState(() {
      _groups.removeAt(groupIndex);
      if (_selectedPeer == group) _selectedPeer = null;
    });
    _syncGroupsToStorage();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You were removed from "${group.nickname}".')),
      );
    }
  }

  /// Any current member (including the introducer) can propose extending
  /// the allow-list from the group settings dialog. Non-introducers send
  /// the proposal to the introducer to apply; the introducer applies it
  /// directly, since it's already the authority.
  void _handleAddAllowedKeys(ChatPeer group, List<String> newKeys) {
    final cleaned = newKeys
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty && k != _myRawPublicKey)
        .where((k) => !group.allowedJoinerKeys.contains(k))
        .toList();
    if (cleaned.isEmpty) return;

    if (group.groupIntroducerKey == _myRawPublicKey) {
      _applyAllowListChange(group, addKeys: cleaned, removeKeys: const []);
    } else if (group.groupIntroducerKey != null) {
      _sessionManager?.sendGroupAllowListChangeRequest(
        introducerKey: group.groupIntroducerKey!,
        groupId: group.rawPublicKey,
        addKeys: cleaned,
        removeKeys: const [],
      );
    }
  }

  /// Removes [keyToRemove] from the allow-list. If it belongs to a current
  /// member, that member is kicked from the group as a consequence. Same
  /// introducer-vs-proposal split as [_handleAddAllowedKeys].
  void _handleRemoveAllowedKey(ChatPeer group, String keyToRemove) {
    if (group.groupIntroducerKey == _myRawPublicKey) {
      _applyAllowListChange(
        group,
        addKeys: const [],
        removeKeys: [keyToRemove],
      );
    } else if (group.groupIntroducerKey != null) {
      _sessionManager?.sendGroupAllowListChangeRequest(
        introducerKey: group.groupIntroducerKey!,
        groupId: group.rawPublicKey,
        addKeys: const [],
        removeKeys: [keyToRemove],
      );
    }
  }

  void _handleGroupReadReceipt(
    String senderPublicKey,
    String groupId,
    String targetMsgId,
  ) async {
    final cleanedSenderKey = senderPublicKey.trim();
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    final msgIndex = group.messages.indexWhere((m) => m.id == targetMsgId);
    if (msgIndex == -1) return;

    final message = group.messages[msgIndex];
    if (!message.isMe) return; // only my own messages track read-by state

    if (mounted) {
      setState(() {
        message.readByKeys.add(cleanedSenderKey);
      });
    }

    await StorageService.persistEncryptedMessage(
      peerPublicKey: groupId,
      msgId: targetMsgId,
      encryptedPayload: message.text,
      isMe: true,
      timestampIso: message.timestamp.toIso8601String(),
      readByKeys: message.readByKeys,
    );
  }

  /// Applies an incoming group reaction update: mirrors [onReactionReceived]
  /// (the 1:1 case), just scoped to a group. Anyone can react to any
  /// message in the group - unlike delete, there's no "only the author"
  /// restriction here, since reacting doesn't change the message itself.
  void _handleGroupReaction(
    String senderPublicKey,
    String groupId,
    String targetMsgId,
    String emoji,
    bool isAdd,
  ) async {
    final cleanedSenderKey = senderPublicKey.trim();
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    if (!group.groupMemberKeys.contains(cleanedSenderKey)) return;

    final msgIndex = group.messages.indexWhere((m) => m.id == targetMsgId);
    if (msgIndex == -1) return;

    final message = group.messages[msgIndex];

    if (mounted) {
      setState(() {
        _applyReactionChange(
          message: message,
          emoji: emoji,
          reactorKey: cleanedSenderKey,
          isAdd: isAdd,
        );
      });
    }

    await StorageService.persistEncryptedMessage(
      peerPublicKey: groupId,
      msgId: targetMsgId,
      encryptedPayload: message.text,
      isMe: message.isMe,
      timestampIso: message.timestamp.toIso8601String(),
      reactions: message.reactions,
    );
  }

  void _handleGroupMessageDeleted(
    String senderPublicKey,
    String groupId,
    String targetMsgId,
  ) {
    final groupIndex = _groups.indexWhere((g) => g.rawPublicKey == groupId);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    final cleanedSenderKey = senderPublicKey.trim();
    // Must be an actual current member, mirroring the membership check
    // `onGroupMessageReceived` already applies.
    if (!group.groupMemberKeys.contains(cleanedSenderKey)) return;

    final removedMsgIndex = group.messages.indexWhere((m) => m.id == targetMsgId);
    if (removedMsgIndex == -1) return;

    final targetMsg = group.messages[removedMsgIndex];
    // Being a member of the group isn't enough authorization on its own -
    // only the message's original author may delete it for everyone.
    // `isMe` means I authored it (so nobody else's delete notice for it is
    // legitimate); otherwise the notice's sender must match who actually
    // sent this particular message.
    if (targetMsg.isMe || targetMsg.senderKey != cleanedSenderKey) return;

    _deleteCachedMediaFile(targetMsg);
    if (mounted) {
      setState(() {
        group.messages.removeWhere((m) => m.id == targetMsgId);
      });
    }
    StorageService.deleteMessage(peerPublicKey: groupId, msgId: targetMsgId);
  }

  void _sendMessage() async {
    if (_msgController.text.isEmpty ||
        _selectedPeer == null ||
        _sessionManager == null) {
      return;
    }

    if (_selectedPeer!.isGroup && _selectedPeer!.isPending) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Still waiting for approval to join this group.'),
        ),
      );
      return;
    }

    final text = _msgController.text;
    // Snapshot whatever's staged as a reply target *before* any awaits -
    // `_replyingTo` is only cleared once the send actually succeeds (see
    // below), so a failed send followed by the "Retry" action still has
    // the same reply context to attach.
    final ChatMessage? replyingToSnapshot = _replyingTo;
    final String? replyToId = replyingToSnapshot?.id;
    final String? replyToText =
        replyingToSnapshot != null ? _replyPreviewText(replyingToSnapshot) : null;
    final String? replyToSenderKey = replyingToSnapshot != null
        ? _originalSenderKeyFor(replyingToSnapshot)
        : null;
    final bool replyToIsMedia = replyingToSnapshot?.isMedia ?? false;
    final String? replyToMediaType = replyingToSnapshot?.mediaType;

    final newMsg = ChatMessage(
      text,
      true,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSenderKey: replyToSenderKey,
      replyToIsMedia: replyToIsMedia,
      replyToMediaType: replyToMediaType,
    );
    final bool isSavedMessagesChat =
        _selectedPeer!.rawPublicKey == StorageService.savedMessagesPeerKey;

    try {
      List<String> failedMembers = const [];

      if (isSavedMessagesChat) {
        // Saved Messages has no one on the other end to send to - it's a
        // local notebook, so just persist it. No network call at all.
        await StorageService.forwardToSavedMessages(
          msgId: newMsg.id,
          encryptedPayload: text,
          timestampIso: newMsg.timestamp.toIso8601String(),
          replyToId: replyToId,
          replyToText: replyToText,
          replyToSenderKey: replyToSenderKey,
          replyToIsMedia: replyToIsMedia,
          replyToMediaType: replyToMediaType,
        );
      } else if (_selectedPeer!.isGroup) {
        // The app may still be mid-reconnect (e.g. right after resuming
        // from a brief backgrounding) - wait it out instead of racing it.
        final bool connected = (_sessionManager?.isServerConnected ?? false) ||
            await _sessionManager!.waitUntilConnected();
        if (!connected) {
          throw const SocketException('No connection to the relay server');
        }

        failedMembers = await _sessionManager!.sendGroupMessage(
          memberKeys: _selectedPeer!.groupMemberKeys,
          groupId: _selectedPeer!.rawPublicKey,
          text: text,
          msgId: newMsg.id,
          timestamp: newMsg.timestamp,
          replyToId: replyToId,
          replyToText: replyToText,
          replyToSenderKey: replyToSenderKey,
          replyToIsMedia: replyToIsMedia,
          replyToMediaType: replyToMediaType,
        );
        if (_selectedPeer!.groupMemberKeys.isNotEmpty &&
            failedMembers.length == _selectedPeer!.groupMemberKeys.length) {
          throw const SocketException('No connection to the relay server');
        }

        await StorageService.persistEncryptedMessage(
          peerPublicKey: _selectedPeer!.rawPublicKey,
          msgId: newMsg.id,
          encryptedPayload: text,
          isMe: true,
          timestampIso: newMsg.timestamp.toIso8601String(),
          replyToId: replyToId,
          replyToText: replyToText,
          replyToSenderKey: replyToSenderKey,
          replyToIsMedia: replyToIsMedia,
          replyToMediaType: replyToMediaType,
        );
      } else {
        final bool connected = (_sessionManager?.isServerConnected ?? false) ||
            await _sessionManager!.waitUntilConnected();
        if (!connected) {
          throw const SocketException('No connection to the relay server');
        }

        await _sessionManager!.sendChatMessage(
          targetKey: _selectedPeer!.rawPublicKey.trim(),
          text: text,
          msgId: newMsg.id,
          timestamp: newMsg.timestamp,
          replyToId: replyToId,
          replyToText: replyToText,
          replyToSenderKey: replyToSenderKey,
          replyToIsMedia: replyToIsMedia,
          replyToMediaType: replyToMediaType,
        );

        await StorageService.persistEncryptedMessage(
          peerPublicKey: _selectedPeer!.rawPublicKey.trim(),
          msgId: newMsg.id,
          encryptedPayload: text,
          isMe: true,
          timestampIso: newMsg.timestamp.toIso8601String(),
          replyToId: replyToId,
          replyToText: replyToText,
          replyToSenderKey: replyToSenderKey,
          replyToIsMedia: replyToIsMedia,
          replyToMediaType: replyToMediaType,
        );
      }

      if (!mounted) return;
      setState(() {
        _selectedPeer!.messages.add(newMsg);
        _replyingTo = null;
      });

      _msgController.clear();
      _scrollToBottom();
      _msgFocusNode.requestFocus();

      if (failedMembers.isNotEmpty && mounted) {
        final int delivered =
            _selectedPeer!.groupMemberKeys.length - failedMembers.length;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Delivered to $delivered of ${_selectedPeer!.groupMemberKeys.length} '
              'group members - ${failedMembers.length} did not receive it.',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Failed to send message: $e');
      final bool isConnectionIssue = e is SocketException || e is StateError;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isConnectionIssue
                ? 'No connection to the relay server - message not sent. Your text is still in the box, try again once reconnected.'
                : 'Failed to deliver message: $e',
          ),
          action: SnackBarAction(label: 'Retry', onPressed: _sendMessage),
        ),
      );
    }
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _jumpToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  void _syncPeersToStorage() async {
    final serialized = _peers
        .map((p) => {"nickname": p.nickname, "publicKey": p.rawPublicKey})
        .toList();
    await StorageService.savePeerList(serialized);
  }

  Future<void> _selectAndLoadPeer(ChatPeer p) async {
    final records = p.rawPublicKey == StorageService.savedMessagesPeerKey
        ? StorageService.fetchSavedMessages()
        : await StorageService.fetchHistory(p.rawPublicKey);
    List<ChatMessage> loadedMessages = [];
    for (var record in records) {
      loadedMessages.add(
        ChatMessage(
          record['payload'] ?? '',
          record['isMe'] == true,
          customTime: DateTime.parse(record['timestamp']),
          customId: record['id'],
          mediaType: record['mediaType'] as String?,
          mediaFileName: record['mediaFileName'] as String?,
          mediaId: record['mediaId'] as String?,
          mediaKeyBase64: record['mediaKeyBase64'] as String?,
          mediaIvBase64: record['mediaIvBase64'] as String?,
          localPath: record['localPath'] as String?,
          reactions: _parseReactions(record['reactions']),
          readByKeys: _parseStringSet(record['readByKeys']),
          senderKey: record['senderKey'] as String?,
          replyToId: record['replyToId'] as String?,
          replyToText: record['replyToText'] as String?,
          replyToSenderKey: record['replyToSenderKey'] as String?,
          replyToIsMedia: record['replyToIsMedia'] == true,
          replyToMediaType: record['replyToMediaType'] as String?,
        )..isRead = record['isRead'] == true,
      );
    }

    if (!mounted) return;
    setState(() {
      p.messages = loadedMessages;
      _selectedPeer = p;
      _isMobileSidebarExpanded = false;
      _autoScroll = true;
      // Bubble keys and any in-flight highlight belong to whichever chat
      // was previously open - stale entries would otherwise pile up
      // forever and could momentarily point `Scrollable.ensureVisible` at
      // a widget from the chat we just left.
      _messageBubbleKeys.clear();
      _highlightedMessageId = null;
      _replyingTo = null;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToBottom();
    });

    if (p.rawPublicKey == StorageService.savedMessagesPeerKey) return;
    if (p.isGroup && p.isPending) return; // not admitted yet

    for (var m in p.messages) {
      if (!m.isMe && !m.isRead) {
        if (p.isGroup) {
          if (m.senderKey != null) {
            _sessionManager?.sendGroupReadReceipt(
              m.senderKey!,
              p.rawPublicKey,
              m.id,
            );
          }
        } else {
          _sessionManager?.sendReadReceipt(p.rawPublicKey, m.id);
        }
        m.isRead = true;
        StorageService.persistEncryptedMessage(
          peerPublicKey: p.rawPublicKey.trim(),
          msgId: m.id,
          encryptedPayload: m.text,
          isMe: false,
          isRead: true,
          timestampIso: m.timestamp.toIso8601String(),
        );
      }
    }
  }

  /// Mutates [message]'s reaction map in place: adds or removes
  /// [reactorKey] from the set for [emoji], cleaning up the emoji entry
  /// entirely once nobody's reacting with it anymore. Shared by both the
  /// locally-initiated path ([_toggleReaction]) and the incoming-packet
  /// path, so the two can never drift out of sync with each other.
  void _applyReactionChange({
    required ChatMessage message,
    required String emoji,
    required String reactorKey,
    required bool isAdd,
  }) {
    if (isAdd) {
      message.reactions.putIfAbsent(emoji, () => <String>{}).add(reactorKey);
    } else {
      final set = message.reactions[emoji];
      set?.remove(reactorKey);
      if (set != null && set.isEmpty) {
        message.reactions.remove(emoji);
      }
    }
  }

  /// Reconstructs a reaction map (emoji -> reactor public keys) from the
  /// JSON-ish structure that comes back out of Hive storage.
  Map<String, Set<String>> _parseReactions(dynamic raw) {
    if (raw is! Map) return {};
    final result = <String, Set<String>>{};
    raw.forEach((key, value) {
      if (key is String && value is List) {
        final keys = value.whereType<String>().toSet();
        if (keys.isNotEmpty) result[key] = keys;
      }
    });
    return result;
  }

  /// Reconstructs the set of member public keys who've read a group
  /// message, from whatever list-ish structure comes back out of Hive.
  Set<String> _parseStringSet(dynamic raw) {
    if (raw is! List) return {};
    return raw.whereType<String>().toSet();
  }

  /// Toggles my own reaction with [emoji] on [message]: adds it if I
  /// haven't reacted with it yet, removes it if I have. Used by the
  /// double-tap "thumbs up" shortcut, the reaction picker dialog, and
  /// tapping an existing reaction bubble to un-react. Works the same way
  /// for a group chat as a 1:1 one - the reaction map itself was always
  /// group-shaped (emoji -> set of reactor keys), the only thing that
  /// changes is fanning the update out to every member instead of sending
  /// it to a single peer.
  Future<void> _toggleReaction(ChatMessage message, String emoji) async {
    if (_selectedPeer == null) return;
    // Saved Messages is a local notebook with nobody else to react to -
    // keep reactions scoped to real conversations (1:1 or group) only.
    if (_selectedPeer!.rawPublicKey == StorageService.savedMessagesPeerKey) {
      return;
    }

    final peer = _selectedPeer!;
    final targetKey = peer.rawPublicKey.trim();
    final bool isAdd = !(message.reactions[emoji]?.contains(_myRawPublicKey) ?? false);

    setState(() {
      _applyReactionChange(
        message: message,
        emoji: emoji,
        reactorKey: _myRawPublicKey,
        isAdd: isAdd,
      );
    });

    await StorageService.persistEncryptedMessage(
      peerPublicKey: targetKey,
      msgId: message.id,
      encryptedPayload: message.text,
      isMe: message.isMe,
      timestampIso: message.timestamp.toIso8601String(),
      reactions: message.reactions,
    );

    if (peer.isGroup) {
      final failedMembers = await _sessionManager?.sendGroupReactionUpdate(
        memberKeys: peer.groupMemberKeys,
        groupId: targetKey,
        messageId: message.id,
        emoji: emoji,
        isAdd: isAdd,
      );
      if ((failedMembers?.isNotEmpty ?? false) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Reaction not delivered to ${failedMembers!.length} of '
              '${peer.groupMemberKeys.length} group members.',
            ),
          ),
        );
      }
    } else {
      _sessionManager?.sendReactionUpdate(targetKey, message.id, emoji, isAdd);
    }
  }

  void _showDynamicContextMenu(
    BuildContext context,
    TapDownDetails details,
    ChatMessage message,
  ) {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;

    final bool isSavedMessagesChat =
        _selectedPeer?.rawPublicKey == StorageService.savedMessagesPeerKey;
    final bool isGroupChat = _selectedPeer?.isGroup ?? false;

    showMenu(
      context: context,
      position: RelativeRect.fromRect(
        details.globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (!isSavedMessagesChat)
          const PopupMenuItem(
            value: 'react',
            child: Row(
              children: [
                Icon(
                  Icons.add_reaction_outlined,
                  size: 16,
                  color: Colors.white70,
                ),
                SizedBox(width: 10),
                Text('React'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'reply',
          child: Row(
            children: [
              Icon(Icons.reply_rounded, size: 16, color: Colors.white70),
              SizedBox(width: 10),
              Text('Reply'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 16, color: Colors.white70),
              SizedBox(width: 10),
              Text('Copy'),
            ],
          ),
        ),
        if (isGroupChat && message.isMe)
          const PopupMenuItem(
            value: 'readBy',
            child: Row(
              children: [
                Icon(Icons.visibility_outlined, size: 16, color: Colors.white70),
                SizedBox(width: 10),
                Text('Read By'),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'save',
          child: Row(
            children: [
              Icon(
                Icons.bookmark_outline_rounded,
                size: 16,
                color: Colors.white70,
              ),
              SizedBox(width: 10),
              Text('Save'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(
                Icons.delete_outline_rounded,
                size: 16,
                color: Colors.redAccent,
              ),
              SizedBox(width: 10),
              Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
      elevation: 8,
    ).then((selectedValue) async {
      if (!mounted || selectedValue == null) return;
      if (selectedValue == 'react') {
        Dialogs.showReactionPicker(
          context: context,
          onSelected: (emoji) => _toggleReaction(message, emoji),
        );
      } else if (selectedValue == 'reply') {
        _startReply(message);
      } else if (selectedValue == 'copy') {
        Clipboard.setData(ClipboardData(text: message.text));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message copied to clipboard'),
            duration: Duration(seconds: 1),
          ),
        );
      } else if (selectedValue == 'readBy') {
        Dialogs.showReadByDialog(
          context: context,
          readerLabels: message.readByKeys.map(_displayNameFor).toList(),
        );
      } else if (selectedValue == 'delete') {
        final bool isSavedMessagesChat =
            _selectedPeer?.rawPublicKey == StorageService.savedMessagesPeerKey;

        await _deleteCachedMediaFile(message);

        setState(() {
          _selectedPeer?.messages.removeWhere((m) => m.id == message.id);
        });

        if (isSavedMessagesChat) {
          // Local notebook - nobody else to tell.
          await StorageService.deleteSavedMessage(message.id);
        } else if (_selectedPeer != null) {
          final targetKey = _selectedPeer!.rawPublicKey.trim();
          await StorageService.deleteMessage(
            peerPublicKey: targetKey,
            msgId: message.id,
          );
          // Only the original author can delete a message for everyone
          // else - deleting someone else's message here only removes it
          // from my own local view, same as any other messenger's
          // "delete for me".
          if (message.isMe) {
            if (_selectedPeer!.isGroup) {
              _sessionManager?.sendGroupDeleteNotice(
                _selectedPeer!.groupMemberKeys,
                targetKey,
                message.id,
              );
            } else {
              _sessionManager?.sendDeleteNotice(targetKey, message.id);
            }
          }
        }

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message deleted'),
            duration: Duration(seconds: 1),
          ),
        );
      } else if (selectedValue == 'save') {
        await StorageService.forwardToSavedMessages(
          msgId: DateTime.now().millisecondsSinceEpoch.toString(),
          encryptedPayload: message.text,
          timestampIso: DateTime.now().toIso8601String(),
          mediaType: message.mediaType,
          mediaFileName: message.mediaFileName,
          localPath: message.localPath,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message saved'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    });
  }

  /// Opens the "+" menu behind both sidebars: Create Group, Join Group,
  /// or Add Contact (the original single-purpose dialog, unchanged and
  /// still reachable, just one tap further in now).
  void _showAddMenu() {
    Dialogs.showAddOptions(
      context: context,
      onCreateGroup: () => Dialogs.showCreateGroup(
        context: context,
        contacts: _peers,
        onCreate: _handleCreateGroup,
      ),
      onJoinGroup: () => Dialogs.showJoinGroup(
        context: context,
        onJoin: _handleJoinGroup,
      ),
      onAddContact: () => Dialogs.showAddPeer(
        context: context,
        nameController: _nameController,
        keyInputController: _keyInputController,
        onConnect: _handleConnectNewPeer,
      ),
    );
  }

  /// Opens the group settings dialog: shows the (always-valid, member-
  /// independent) invite code and lets any current member extend or shrink
  /// the allow-list. Removing a key that belongs to a current member kicks
  /// them from the group.
  void _showGroupSettings(ChatPeer group) {
    // Older groups (created before the creator's own key was seeded onto
    // the allow-list) may not have it yet - add it defensively so the
    // owner always shows up (as "You") and can be removed like anyone
    // else, regardless of when the group was created.
    final displayedAllowedKeys = [
      if (group.groupIntroducerKey != null &&
          !group.allowedJoinerKeys.contains(group.groupIntroducerKey))
        group.groupIntroducerKey!,
      ...group.allowedJoinerKeys,
    ];
    Dialogs.showGroupSettings(
      context: context,
      groupName: group.nickname,
      inviteCode: _buildInviteCode(group),
      allowedJoinerKeys: displayedAllowedKeys,
      labelForKey: _displayNameFor,
      onAddAllowedKeys: (keys) => _handleAddAllowedKeys(group, keys),
      onRemoveAllowedKey: (key) => _handleRemoveAllowedKey(group, key),
    );
  }

  /// Shown on long-pressing a contact in either sidebar - lets you copy
  /// their public key so you can paste it into another group's allow-list
  /// or the "Add Contact" dialog.
  void _showPeerKeyMenu(ChatPeer p) {
    if (p.isGroup || p.rawPublicKey == StorageService.savedMessagesPeerKey) {
      return;
    }
    Dialogs.showPeerKeyDialog(
      context: context,
      nickname: p.nickname,
      rawPublicKey: p.rawPublicKey,
    );
  }

  void _showSettingsDialog() {
    Dialogs.showSettingsDialog(
      context: context,
      ipController: _ipController,
      onResetIdentity: _resetIdentity,
      onSaveAndConnect: (targetIp) {
        if (!mounted) return;
        setState(() => _serverIp = targetIp);
        _startSession();
      },
    );
  }

  void _resetIdentity() async {
    final kp = RSAKeypair.fromRandom();
    await StorageService.resetIdentity();
    await StorageService.savePrivateKey(kp.privateKey.toString());

    if (!mounted) return;
    setState(() {
      _privKey = kp.privateKey;
      _myRawPublicKey = kp.publicKey.toString().trim();
      _myShortId = _myRawPublicKey.substring(_myRawPublicKey.length - 15);
      _peers.clear();
      _groups.clear();
      _selectedPeer = null;
      _onlinePeers.clear();
    });
    _startSession();
  }

  Widget _buildMainContentSection(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isSavedMessagesChat =
        _selectedPeer?.rawPublicKey == StorageService.savedMessagesPeerKey;

    if (_selectedPeer == null) {
      return const Expanded(
        child: Center(
          child: Text(
            'No Chat Selected',
            style: TextStyle(color: Colors.white30),
          ),
        ),
      );
    }

    return Expanded(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 73,
              child: Center(
                child: GestureDetector(
                  onLongPress:
                      (_selectedPeer!.isGroup && !_selectedPeer!.isPending)
                      ? () => _showGroupSettings(_selectedPeer!)
                      : null,
                  child: ListTile(
                    title: Text(
                      _selectedPeer!.nickname,
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Text(
                      isSavedMessagesChat
                          ? 'Save messages here via the right-click / hold menu.'
                          : _selectedPeer!.isGroup
                          ? (_selectedPeer!.isPending
                                ? 'Awaiting approval to join...'
                                : '${_selectedPeer!.groupMemberKeys.length + 1} members - hold name for settings')
                          : 'Target: ${_selectedPeer!.shortId}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const RoundedDivider(),
            const SizedBox(height: 5),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (scrollInfo) {
                  final isAtBottom =
                      scrollInfo.metrics.pixels >=
                      (scrollInfo.metrics.maxScrollExtent - 20);
                  if (isAtBottom && !_autoScroll) {
                    _autoScroll = true;
                    _checkAndSendPendingReceipts();
                  } else if (!isAtBottom &&
                      _autoScroll &&
                      scrollInfo is ScrollUpdateNotification &&
                      scrollInfo.dragDetails != null) {
                    setState(() {
                      _autoScroll = false;
                    });
                  }
                  return true;
                },
                child: ListView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: const EdgeInsets.all(24),
                  children: _selectedPeer!.messages
                      .map((m) => _buildMessageBubble(m, context))
                      .toList(),
                ),
              ),
            ),
            _buildMessageInputField(context),
          ],
        ),
      ),
    );
  }

  /// Whether a message I sent counts as "read": for a 1:1 chat that's just
  /// [ChatMessage.isRead]; for a group it's "at least one other member has
  /// sent back a receipt" - requiring *every* member breaks the moment
  /// membership changes (a message sent before someone joined can never be
  /// seen by them, so it could never be marked read again), and matches
  /// the simple single-tick-vs-double-tick feel of the 1:1 indicator.
  /// [_buildReadByMenuEntry] is where you see exactly *who's* read it.
  bool _isMessageRead(ChatMessage m, bool isGroupChat) {
    if (!isGroupChat) return m.isRead;
    return m.readByKeys.isNotEmpty;
  }

  /// Resolves a group message sender's raw public key to something
  /// readable: their nickname if they're already one of your contacts,
  /// otherwise their short ID (same fallback [ChatPeer.shortId] uses).
  String _displayNameFor(String rawPublicKey) {
    if (rawPublicKey == _myRawPublicKey) return 'You';
    final known = _peers.where((p) => p.rawPublicKey.trim() == rawPublicKey);
    if (known.isNotEmpty) return known.first.nickname;
    return rawPublicKey.length > 15
        ? rawPublicKey.substring(rawPublicKey.length - 15)
        : rawPublicKey;
  }

  /// Returns (creating if necessary) the [GlobalKey] a message bubble is
  /// built with, so a quoted-reply tap can later locate its render object
  /// via [Scrollable.ensureVisible].
  GlobalKey _keyForMessage(String id) =>
      _messageBubbleKeys.putIfAbsent(id, () => GlobalKey());

  /// Stages [m] as the message a new outgoing message will reply to -
  /// shows the compose-bar preview and focuses the input. Works exactly
  /// the same for a group chat as a 1:1 one: what actually travels on the
  /// wire is just [ChatMessage.senderKey]/[ChatMessage.isMe], which are
  /// already resolved per-chat-type.
  void _startReply(ChatMessage m) {
    setState(() => _replyingTo = m);
    _msgFocusNode.requestFocus();
  }

  void _cancelReply() => setState(() => _replyingTo = null);

  /// The raw public key of whoever actually sent [m], from the current
  /// chat's point of view - `myRawPublicKey` if I sent it, otherwise
  /// either its `senderKey` (group chats) or the open peer's key (1:1
  /// chats, which never populate `senderKey` on inbound messages).
  String? _originalSenderKeyFor(ChatMessage m) {
    if (m.isMe) return _myRawPublicKey;
    return m.senderKey ?? _selectedPeer?.rawPublicKey.trim();
  }

  /// Short human label for who a reply-in-progress or reply-quote is
  /// pointing at: "You" for my own messages, otherwise the usual
  /// nickname/short-id resolution.
  String _authorLabelFor(String? rawPublicKey) {
    if (rawPublicKey == null) return 'Unknown';
    return _displayNameFor(rawPublicKey);
  }

  /// The one-line snippet shown both in the compose-bar reply preview and
  /// (as a snapshot baked into the outgoing payload) in the recipient's
  /// quoted-reply block: the message's own text if it has any, otherwise
  /// a fallback label for its attachment type.
  String _replyPreviewText(ChatMessage m) {
    if (m.text.trim().isNotEmpty) return m.text;
    if (m.isMedia) return _mediaReplyLabel(m.mediaType);
    return '';
  }

  String _mediaReplyLabel(String? mediaType) {
    switch (mediaType) {
      case 'image':
        return '📷 Photo';
      case 'video':
        return '🎞️ Video';
      case 'audio':
        return '🎵 Audio';
      default:
        return '📄 Document';
    }
  }

  /// Scrolls the original message a reply is quoting into view and briefly
  /// flashes its background, exactly like tapping a reply quote does in
  /// Telegram/WhatsApp. If the original isn't currently rendered (deleted,
  /// or simply hasn't loaded), this fails quietly with a toast instead of
  /// throwing.
  void _scrollToAndHighlightMessage(String messageId) {
    final ctx = _messageBubbleKeys[messageId]?.currentContext;
    if (ctx == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Original message not available.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.5,
    );

    _highlightClearTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightClearTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  /// The small quoted block shown at the top of a reply's bubble - author
  /// label plus a one-line snippet of whatever it's replying to, using the
  /// snapshot carried in the payload so it still renders even if the
  /// original was since deleted locally. Tapping it jumps to (and briefly
  /// highlights) the original message if it's still around.
  Widget _buildReplyQuote(ChatMessage m, BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String authorLabel = _authorLabelFor(m.replyToSenderKey);
    final String snippet = (m.replyToText?.trim().isNotEmpty ?? false)
        ? m.replyToText!.trim()
        : (m.replyToIsMedia ? _mediaReplyLabel(m.replyToMediaType) : '');

    return GestureDetector(
      onTap: () => _scrollToAndHighlightMessage(m.replyToId!),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(6),
          border: Border(
            left: BorderSide(color: theme.colorScheme.primary, width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              authorLabel,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            if (snippet.isNotEmpty)
              Text(
                snippet,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

Widget _buildMessageBubble(ChatMessage m, BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String timeString =
        "${m.timestamp.hour.toString().padLeft(2, '0')}:${m.timestamp.minute.toString().padLeft(2, '0')}";
    TapDownDetails? tapDetails;
    final bool isSavedMessagesChat =
        _selectedPeer?.rawPublicKey == StorageService.savedMessagesPeerKey;
    final bool isGroupChat = _selectedPeer?.isGroup ?? false;
    // Saved Messages is a local notebook with nobody else to react - every
    // other chat (1:1 or group) supports reactions.
    final bool reactionsDisabled = isSavedMessagesChat;

    return KeyedSubtree(
      key: _keyForMessage(m.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        color: _highlightedMessageId == m.id
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        child: Align(
      alignment: m.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: TweenAnimationBuilder<double>(
        key: ValueKey(m.id),
        tween: Tween<double>(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          return Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, 10 * (1.0 - value)),
              child: child,
            ),
          );
        },
        child: Column(
          crossAxisAlignment: m.isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (isGroupChat && !m.isMe && m.senderKey != null)
              Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 2),
                child: Text(
                  _displayNameFor(m.senderKey!),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            SwipeToReply(
              onReply: () => _startReply(m),
              child: GestureDetector(
              onTapDown: (details) => tapDetails = details,
              onSecondaryTapDown: (details) {
                tapDetails = details;
                _showDynamicContextMenu(context, tapDetails!, m);
              },
              onLongPress: () {
                if (tapDetails != null) {
                  _showDynamicContextMenu(context, tapDetails!, m);
                }
              },
              // Double-tap/double-click is a shortcut for a 👍 reaction -
              // no-op in Saved Messages, same as every other reaction path.
              onDoubleTap: reactionsDisabled
                  ? null
                  : () => _toggleReaction(m, '👍'),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: m.isMe
                      ? const Color(0xFF0B0B0B)
                      : const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(12),
                  border: m.isMe
                      ? Border.all(color: Colors.white10, width: 0.5)
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (m.replyToId != null)
                      _buildReplyQuote(m, context),
                    if (m.isMedia) ...[
                      _buildInteractiveMediaContent(m),
                      if (m.text.trim().isNotEmpty) const SizedBox(height: 8),
                    ],
                    if (m.text.trim().isNotEmpty)
                    MarkdownBody(
                      data: m.text,
                      selectable: false,
                      onTapLink: (text, href, title) async {
                        if (href != null) {
                          final Uri url = Uri.parse(href);
                          if (await canLaunchUrl(url)) {
                            await launchUrl(
                              url,
                              mode: LaunchMode.externalApplication,
                            );
                          } else {
                            debugPrint('Could not launch link: $href');
                          }
                        }
                      },
                      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                          .copyWith(
                            p: const TextStyle(color: Colors.white, fontSize: 14),
                            code: TextStyle(
                              backgroundColor: Colors.black26,
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: theme.colorScheme.primary,
                            ),
                            blockquoteDecoration: BoxDecoration(
                              color: const Color.fromARGB(66, 90, 90, 90),
                              borderRadius: BorderRadius.all(Radius.circular(10)),
                            ),
                            a: TextStyle(color: theme.colorScheme.primary),
                          ),
                    ),
                  ],
                ),
              ),
            ),
            ),
            if (m.reactions.isNotEmpty) _buildReactionsRow(m, context),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    timeString,
                    style: const TextStyle(color: Colors.white30, fontSize: 11),
                  ),
                  if (!isSavedMessagesChat && m.isMe)
                    Padding(
                      padding: const EdgeInsets.only(left: 6.0),
                      child: Icon(
                        _isMessageRead(m, isGroupChat)
                            ? Icons.circle
                            : Icons.radio_button_unchecked,
                        size: 7,
                        color: _isMessageRead(m, isGroupChat)
                            ? theme.colorScheme.primary
                            : Colors.white24,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
        ),
      ),
    );
  }

  /// A row of small pill-shaped chips beneath a message bubble, one per
  /// emoji that's been reacted with, each showing the stacked avatars of
  /// whoever reacted plus the emoji itself. Tapping a chip toggles *my*
  /// reaction with that emoji (un-reacting if I'm already in it).
  Widget _buildReactionsRow(ChatMessage m, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: m.reactions.entries
            .where((entry) => entry.value.isNotEmpty)
            .map((entry) => _buildReactionChip(entry.key, entry.value, m, context))
            .toList(),
      ),
    );
  }

  Widget _buildReactionChip(
    String emoji,
    Set<String> reactorKeys,
    ChatMessage m,
    BuildContext context,
  ) {
    final ThemeData theme = Theme.of(context);
    final bool reactedByMe = reactorKeys.contains(_myRawPublicKey);
    final List<String> ordered = reactorKeys.toList();
    // Only stack avatars for up to 3 reactors so the chip doesn't grow
    // unbounded once group chats are a thing; the trailing count covers
    // the rest.
    final int shownAvatars = ordered.length > 3 ? 3 : ordered.length;

    return GestureDetector(
      onTap: () => _toggleReaction(m, emoji),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: reactedByMe
              ? theme.colorScheme.primary.withValues(alpha: 0.18)
              : Colors.black26,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: reactedByMe ? theme.colorScheme.primary : Colors.white10,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 16,
              width: 12.0 + (shownAvatars * 8.0),
              child: Stack(
                children: [
                  for (int i = 0; i < shownAvatars; i++)
                    Positioned(
                      left: i * 8.0,
                      child: _buildReactorAvatar(ordered[i], theme),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Text(emoji, style: const TextStyle(fontSize: 13)),
            if (ordered.length > 1) ...[
              const SizedBox(width: 3),
              Text(
                '${ordered.length}',
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// A tiny circular initial-letter avatar for one reactor, built the same
  /// way as the peer avatars in [CompactSidebar]/[ExpandedSidebar] so
  /// reaction chips look consistent with the rest of the app.
  Widget _buildReactorAvatar(String reactorKey, ThemeData theme) {
    final bool isSelf = reactorKey == _myRawPublicKey;
    // _displayNameFor already knows how to resolve any group member (or a
    // 1:1 peer) to a nickname, with a short-ID fallback - reused here
    // instead of assuming the reactor is always the currently selected
    // peer, which only held for 1:1 chats.
    final String otherName = _displayNameFor(reactorKey);
    final String label = isSelf
        ? 'Y'
        : (otherName.isNotEmpty ? otherName[0].toUpperCase() : '?');

    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.primary,
        border: Border.all(color: const Color(0xFF141414), width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.bold,
          color: Colors.black,
        ),
      ),
    );
  }

  Widget _buildInteractiveMediaContent(ChatMessage m) {
    if (m.isTransferring) {
      return Container(
        width: 140,
        height: 100,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  m.isMe ? Icons.cloud_upload_rounded : Icons.cloud_download_rounded,
                  color: Colors.white54,
                  size: 28,
                ),
                const SizedBox(height: 6),
                Text(
                  m.mediaFileName ?? (m.isMe ? 'Uploading...' : 'Downloading...'),
                  style: const TextStyle(color: Colors.white30, fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            // Only outgoing uploads can be cancelled - an incoming
            // download's metadata has already been delivered and
            // persisted, so "cancelling" it would just orphan the
            // message with no way to fetch its attachment later.
            if (m.isMe)
            Positioned(
              right: 8,
              top: 8,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    m.isCancelled = true;
                    m.isTransferring = false;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              bottom: 12,
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  value: m.isMe ? m.uploadProgress : null,
                  strokeWidth: 2.5,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (m.downloadFailed) {
      return GestureDetector(
        onTap: () => _retryDownload(m),
        child: Container(
          width: 200,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.redAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Download failed - tap to retry',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (m.sendFailed && m.isMe && _selectedPeer != null) {
      return GestureDetector(
        onTap: () => _retrySendMedia(m, _selectedPeer!),
        child: Container(
          width: 200,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.redAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Send failed - tap to retry',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final File? localFile =
        (m.localPath != null && m.localPath!.isNotEmpty) ? File(m.localPath!) : null;
    final bool hasLocalFile = localFile != null && localFile.existsSync();

    if (m.mediaType == 'image' && hasLocalFile) {
      return GestureDetector(
        onTap: () async {
          final previewBytes = await _resolveOrFetchMediaBytes(m);
          if (previewBytes == null || !mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ImagePreviewWidget(
                fileName: m.mediaFileName ?? 'image.png',
                bytes: previewBytes,
              ),
            ),
          );
        },
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 180),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(localFile, fit: BoxFit.cover),
          ),
        ),
      );
    } else if (m.mediaType == 'video' && hasLocalFile) {
      return VideoPlayerWidget(
        file: localFile,
        onDownload: () => _saveAttachmentToDevice(m),
      );
    } else if (m.mediaType == 'audio' && hasLocalFile) {
      return AudioPlayerWidget(
        file: localFile,
        onDownload: () => _saveAttachmentToDevice(m),
      );
    }

    // Fallback for documents, and for image/video/audio messages whose
    // local cache isn't available (cache cleared, or metadata arrived but
    // the auto-download hasn't run yet) - the download button here fetches
    // over HTTP on demand via _resolveOrFetchMediaBytes.
    final bool canDownload = hasLocalFile || m.mediaId != null;
    return Container(
      width: 240,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            m.mediaType == 'audio' ? Icons.audiotrack_rounded : Icons.insert_drive_file_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              m.mediaFileName ?? 'Document',
              style: const TextStyle(color: Colors.white, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (canDownload)
            IconButton(
              icon: const Icon(Icons.download_rounded, size: 18, color: Colors.white60),
              onPressed: () => _saveAttachmentToDevice(m),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageInputField(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_replyingTo != null) _buildReplyComposerPreview(context),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _msgController,
                  focusNode: _msgFocusNode,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(),
                  decoration: InputDecoration(
                    hintText: 'Message...',
                    filled: true,
                    fillColor: const Color(0xFF1E1E1E),
                    prefixIcon: IconButton(
                      onPressed: _pickAndSendMedia,
                      icon: Icon(
                        Icons.add_circle_outline_rounded,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FloatingActionButton(
                backgroundColor: _isMessageEmpty
                    ? Colors.white30
                    : theme.colorScheme.primary,
                onPressed: _isMessageEmpty ? null : _sendMessage,
                child: const Icon(Icons.send_rounded, color: Colors.black),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The small strip shown right above the input field once a reply's been
  /// staged (via swipe or the context menu) - author + snippet of what's
  /// being replied to, with an "X" to cancel back to a normal message.
  Widget _buildReplyComposerPreview(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ChatMessage replyingTo = _replyingTo!;
    final String authorLabel =
        replyingTo.isMe ? 'yourself' : _authorLabelFor(_originalSenderKeyFor(replyingTo));
    final String snippet = _replyPreviewText(replyingTo);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to $authorLabel',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                if (snippet.isNotEmpty)
                  Text(
                    snippet,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white60),
            onPressed: _cancelReply,
            tooltip: 'Cancel reply',
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedOverlayDrawer() {
    return Stack(
      children: [
        IgnorePointer(
          ignoring: !_isMobileSidebarExpanded,
          child: GestureDetector(
            onTap: () => setState(() => _isMobileSidebarExpanded = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              color: _isMobileSidebarExpanded
                  ? Colors.black54
                  : Colors.transparent,
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOutCubic,
          left: _isMobileSidebarExpanded ? 0 : -260,
          top: 0,
          bottom: 0,
          child: SafeArea(
            child: Container(
              width: 260,
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.only(
                  topRight: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
                color: Color(0xFF1A1A1A),
              ),
              child: ExpandedSidebar(
                peers: _sidebarEntries,
                selectedPeer: _selectedPeer,
                onlinePeers: _onlinePeers,
                onSelectPeer: _selectAndLoadPeer,
                onPeerLongPress: _showPeerKeyMenu,
                onSettingsPressed: _showSettingsDialog,
                onAboutPressed: () => Dialogs.showAboutDialog(context: context),
                onIdentityPressed: () => Dialogs.showIdentityModal(
                  context: context,
                  shortId: _myShortId,
                  rawPublicKey: _myRawPublicKey,
                ),
                onAddPeerPressed: _showAddMenu,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_myRawPublicKey.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!(_sessionManager?.isServerConnected ?? false)) {
      return ConnectionSetupScreen(
        ipController: _ipController,
        isConnecting: _sessionManager?.isConnecting ?? false,
        onConnect: () {
          if (_ipController.text.isNotEmpty) {
            setState(() => _serverIp = _ipController.text.trim());
            _startSession();
          }
        },
      );
    }

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bool isSmallScreen = constraints.maxWidth < 700;

          return Stack(
            children: [
              Row(
                children: [
                  if (!isSmallScreen)
                    Container(
                      width: 260,
                      decoration: const BoxDecoration(
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(16),
                          bottomRight: Radius.circular(16),
                        ),
                        color: Color(0xFF1A1A1A),
                      ),
                      child: SafeArea(
                        child: ExpandedSidebar(
                          peers: _sidebarEntries,
                          selectedPeer: _selectedPeer,
                          onlinePeers: _onlinePeers,
                          onSelectPeer: _selectAndLoadPeer,
                          onPeerLongPress: _showPeerKeyMenu,
                          onSettingsPressed: _showSettingsDialog,
                          onAboutPressed: () =>
                              Dialogs.showAboutDialog(context: context),
                          onIdentityPressed: () => Dialogs.showIdentityModal(
                            context: context,
                            shortId: _myShortId,
                            rawPublicKey: _myRawPublicKey,
                          ),
                          onAddPeerPressed: _showAddMenu,
                        ),
                      ),
                    )
                  else
                    CompactSidebar(
                      peers: _sidebarEntries,
                      selectedPeer: _selectedPeer,
                      onlinePeers: _onlinePeers,
                      onSelectPeer: _selectAndLoadPeer,
                      onPeerLongPress: _showPeerKeyMenu,
                      onMenuPressed: () =>
                          setState(() => _isMobileSidebarExpanded = true),
                    ),
                  _buildMainContentSection(context),
                ],
              ),
              if (isSmallScreen) _buildAnimatedOverlayDrawer(),
            ],
          );
        },
      ),
    );
  }
}
