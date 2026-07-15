import 'dart:convert';
import 'dart:io';
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
  ChatPeer? _selectedPeer;
  late RSAPrivateKey _privKey;

  String _serverIp = "localhost:8080";
  String _myRawPublicKey = "";
  String _myShortId = "";
  bool _autoScroll = true;
  bool _isMobileSidebarExpanded = false;
  bool _isMessageEmpty = true;

  Set<String> _onlinePeers = {};

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
        debugPrint("Mobile backgrounding detected: Securing session pipeline.");
        _sessionManager?.disconnect();
      }
    } else if (state == AppLifecycleState.resumed) {
      // If we are on mobile and returning from a paused state, re-establish the connection
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

    final String? savedIp = await StorageService.fetchServerIp();

    if (!mounted) return;
    setState(() {
      _privKey = kp.privateKey;
      _myRawPublicKey = kp.publicKey.toString().trim();
      _myShortId = _myRawPublicKey.substring(_myRawPublicKey.length - 15);
      _peers.addAll(hydratedPeers);

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
            timestampIso: peer.messages[msgIndex].timestamp.toIso8601String(),
          );
        }
      },
      onMessageReceived: (senderPublicKey, text, payloadMap) {
        _processIncomingMessage(senderPublicKey, text, payloadMap);
      },
      onMessageDeleted: (senderPublicKey, targetMsgId) {
        final cleanedSenderKey = senderPublicKey.trim();
        final peerIndex = _peers.indexWhere(
          (p) => p.rawPublicKey.trim() == cleanedSenderKey,
        );
        if (peerIndex == -1) return;

        final peer = _peers[peerIndex];
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

  Future<void> _pickAndSendMedia() async {
    if (_selectedPeer == null || _sessionManager == null) return;

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      withData: false, 
    );
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

    // MATCHED PROPERTY NAMES HERE (isTransferring & uploadProgress)
    final tempMessage = ChatMessage(
      "[Sent an Attachment: $fileName]",
      true,
      customTime: now,
      customId: msgId,
      mediaType: mediaType,
      mediaFileName: fileName,
      localPath: filePath,
      isTransferring: true,
      uploadProgress: 0.05,
    );

    setState(() {
      targetPeer.messages.add(tempMessage);
    });
    _scrollToBottom();

    try {
      final Uint8List fileBytes = await File(filePath).readAsBytes();
      
      if (tempMessage.isCancelled) return; 

      final String base64Payload = base64Encode(fileBytes);
      
      if (tempMessage.isCancelled) return; 

      await _sessionManager!.sendMediaMessage(
        targetKey: cleanedTargetKey,
        msgId: msgId,
        timestamp: now,
        text: "[Sent an Attachment: $fileName]",
        mediaType: mediaType,
        fileName: fileName,
        base64Payload: base64Payload,
        onProgress: (progress) {
          if (tempMessage.isCancelled) {
            throw Exception('Upload cancelled by user.');
          }
          setState(() {
            tempMessage.uploadProgress = progress;
          });
        },
      );

      await StorageService.persistEncryptedMessage(
        peerPublicKey: cleanedTargetKey,
        msgId: msgId,
        isMe: true,
        encryptedPayload: "[Sent an Attachment: $fileName]",
        timestampIso: now.toIso8601String(),
      );

      setState(() {
        tempMessage.isTransferring = false;
        tempMessage.uploadProgress = 1.0;
        tempMessage.localPath = filePath; 
      });

    } catch (e) {
      debugPrint("Failed to process media output pipeline: $e");
      setState(() {
        tempMessage.isTransferring = false;
        tempMessage.uploadProgress = 0.0;
        if (tempMessage.isCancelled) {
          targetPeer.messages.remove(tempMessage);
        }
      });
      
      if (!tempMessage.isCancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to deliver attachment: $e')),
        );
      }
    }
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

  void _processIncomingMessage(
    String senderPublicKey,
    String rawCiphertext,
    Map<String, dynamic> payloadMap,
  ) async {
    bool peerExists = _peers.any(
      (p) => p.rawPublicKey.trim() == senderPublicKey,
    );
    if (!peerExists) return;

    final String messageText = payloadMap['text'];
    final String msgId = payloadMap['msgId'];
    final DateTime sentTime = DateTime.parse(payloadMap['timestamp']);

    final String? mediaType = payloadMap['mediaType'];
    final String? mediaFileName = payloadMap['mediaFileName'];
    final String? base64Data = payloadMap['base64Data'];

    await StorageService.persistEncryptedMessage(
      peerPublicKey: senderPublicKey,
      msgId: msgId,
      encryptedPayload: messageText,
      isMe: false,
      timestampIso: sentTime.toIso8601String(),
    );

    if (!mounted) return;
    setState(() {
      final sender = _peers.firstWhere(
        (p) => p.rawPublicKey.trim() == senderPublicKey,
      );
      if (!sender.messages.any((m) => m.id == msgId)) {
        final newIncomingMsg = ChatMessage(
          messageText,
          false,
          customTime: sentTime,
          customId: msgId,
          mediaType: mediaType,
          mediaFileName: mediaFileName,
          base64Data: base64Data,
        );

        final bool isChatOpenAndVisible =
            _selectedPeer == sender && _isWindowInFocus && _autoScroll;

        if (isChatOpenAndVisible) {
          newIncomingMsg.isRead = true;
          _sessionManager?.sendReadReceipt(senderPublicKey, msgId);
        } else {
          newIncomingMsg.isRead = false;
          NotificationService.showNotification(
            id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            title: "New Message from ${sender.nickname}",
            body: messageText,
          );
        }

        sender.messages.add(newIncomingMsg);
      }
    });
    _scrollToBottom();
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

    bool stateChanged = false;

    for (var m in _selectedPeer!.messages) {
      // If it's an incoming message and hasn't been marked read locally yet
      if (!m.isMe && !m.isRead) {
        _sessionManager!.sendReadReceipt(_selectedPeer!.rawPublicKey, m.id);
        m.isRead = true;
        stateChanged = true;

        // Update local database history so we don't try to send it again next time
        StorageService.persistEncryptedMessage(
          peerPublicKey: _selectedPeer!.rawPublicKey.trim(),
          msgId: m.id,
          encryptedPayload: m.text,
          isMe: false,
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

  void _sendMessage() async {
    if (_msgController.text.isEmpty ||
        _selectedPeer == null ||
        _sessionManager == null) {
      return;
    }

    final text = _msgController.text;
    final newMsg = ChatMessage(text, true);
    final bool isSavedMessagesChat =
        _selectedPeer!.rawPublicKey == StorageService.savedMessagesPeerKey;

    try {
      if (isSavedMessagesChat) {
        // Saved Messages has no one on the other end to send to - it's a
        // local notebook, so just persist it. No network call at all.
        await StorageService.forwardToSavedMessages(
          msgId: newMsg.id,
          encryptedPayload: text,
          timestampIso: newMsg.timestamp.toIso8601String(),
        );
      } else {
        await _sessionManager!.sendChatMessage(
          targetKey: _selectedPeer!.rawPublicKey.trim(),
          text: text,
          msgId: newMsg.id,
          timestamp: newMsg.timestamp,
        );

        await StorageService.persistEncryptedMessage(
          peerPublicKey: _selectedPeer!.rawPublicKey.trim(),
          msgId: newMsg.id,
          encryptedPayload: text,
          isMe: true,
          timestampIso: newMsg.timestamp.toIso8601String(),
        );
      }

      if (!mounted) return;
      setState(() {
        _selectedPeer!.messages.add(newMsg);
      });

      _msgController.clear();
      _scrollToBottom();
      _msgFocusNode.requestFocus();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to deliver message: Connection inactive.'),
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
        )..isRead = record['isRead'] == true,
      );
    }

    if (!mounted) return;
    setState(() {
      p.messages = loadedMessages;
      _selectedPeer = p;
      _isMobileSidebarExpanded = false;
      _autoScroll = true;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToBottom();
    });

    if (p.rawPublicKey == StorageService.savedMessagesPeerKey) return;

    for (var m in p.messages) {
      if (!m.isMe && !m.isRead) {
        _sessionManager?.sendReadReceipt(p.rawPublicKey, m.id);
        m.isRead = true;
      }
    }
  }

  void _showDynamicContextMenu(
    BuildContext context,
    TapDownDetails details,
    ChatMessage message,
  ) {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu(
      context: context,
      position: RelativeRect.fromRect(
        details.globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
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
      if (selectedValue == 'copy') {
        Clipboard.setData(ClipboardData(text: message.text));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message copied to clipboard'),
            duration: Duration(seconds: 1),
          ),
        );
      } else if (selectedValue == 'delete') {
        final bool isSavedMessagesChat =
            _selectedPeer?.rawPublicKey == StorageService.savedMessagesPeerKey;

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
          _sessionManager?.sendDeleteNotice(targetKey, message.id);
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
                        : 'Target: ${_selectedPeer!.shortId}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
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

Widget _buildMessageBubble(ChatMessage m, BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String timeString =
        "${m.timestamp.hour.toString().padLeft(2, '0')}:${m.timestamp.minute.toString().padLeft(2, '0')}";
    TapDownDetails? tapDetails;
    final bool isSavedMessagesChat =
        _selectedPeer?.rawPublicKey == StorageService.savedMessagesPeerKey;

    return Align(
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
            GestureDetector(
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
                    if (m.isMedia) ...[
                      _buildInteractiveMediaContent(m),
                      const SizedBox(height: 8),
                    ],
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
                        m.isRead ? Icons.circle : Icons.radio_button_unchecked,
                        size: 7,
                        color: m.isRead
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
                const Icon(Icons.cloud_upload_rounded, color: Colors.white54, size: 28),
                const SizedBox(height: 6),
                Text(
                  m.mediaFileName ?? 'Uploading...',
                  style: const TextStyle(color: Colors.white30, fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
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
                  value: m.uploadProgress, // FIXED: Changed progress to uploadProgress
                  strokeWidth: 2.5,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final File? localFile = m.localPath != null ? File(m.localPath!) : null;
    final Uint8List? bytes = m.base64Data != null ? base64Decode(m.base64Data!) : null;

    if (m.mediaType == 'image') {
      if (bytes != null) {
        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ImagePreviewWidget(
                  fileName: m.mediaFileName ?? 'image.png',
                  bytes: bytes,
                ),
              ),
            );
          },
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240, maxHeight: 180),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(bytes, fit: BoxFit.cover),
            ),
          ),
        );
      }
    } else if (m.mediaType == 'video' && localFile != null && localFile.existsSync()) {
      return VideoPlayerWidget(file: localFile);
    } else if (m.mediaType == 'audio' && localFile != null && localFile.existsSync()) {
      return AudioPlayerWidget(file: localFile);
    }

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
          if (bytes != null)
            IconButton(
              icon: const Icon(Icons.download_rounded, size: 18, color: Colors.white60),
              onPressed: () {
                // FIXED: Now calls the public saveToDevice method on ImagePreviewWidget
                ImagePreviewWidget(
                  fileName: m.mediaFileName ?? 'attachment.dat',
                  bytes: bytes,
                ).saveToDevice(context);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildMessageInputField(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Row(
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
                peers: _peers,
                selectedPeer: _selectedPeer,
                onlinePeers: _onlinePeers,
                onSelectPeer: _selectAndLoadPeer,
                onSettingsPressed: _showSettingsDialog,
                onAboutPressed: () => Dialogs.showAboutDialog(context: context),
                onIdentityPressed: () => Dialogs.showIdentityModal(
                  context: context,
                  shortId: _myShortId,
                  rawPublicKey: _myRawPublicKey,
                ),
                onAddPeerPressed: () => Dialogs.showAddPeer(
                  context: context,
                  nameController: _nameController,
                  keyInputController: _keyInputController,
                  onConnect: _handleConnectNewPeer,
                ),
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
                          peers: _peers,
                          selectedPeer: _selectedPeer,
                          onlinePeers: _onlinePeers,
                          onSelectPeer: _selectAndLoadPeer,
                          onSettingsPressed: _showSettingsDialog,
                          onAboutPressed: () =>
                              Dialogs.showAboutDialog(context: context),
                          onIdentityPressed: () => Dialogs.showIdentityModal(
                            context: context,
                            shortId: _myShortId,
                            rawPublicKey: _myRawPublicKey,
                          ),
                          onAddPeerPressed: () => Dialogs.showAddPeer(
                            context: context,
                            nameController: _nameController,
                            keyInputController: _keyInputController,
                            onConnect: _handleConnectNewPeer,
                          ),
                        ),
                      ),
                    )
                  else
                    CompactSidebar(
                      peers: _peers,
                      selectedPeer: _selectedPeer,
                      onlinePeers: _onlinePeers,
                      onSelectPeer: _selectAndLoadPeer,
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
