import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypton/crypton.dart';
import 'models.dart';
import 'dialogs.dart';
import 'storage_service.dart';

class DecentralizedChat extends StatefulWidget {
  const DecentralizedChat({super.key});

  @override
  State<DecentralizedChat> createState() => _DecentralizedChatState();
}

class _DecentralizedChatState extends State<DecentralizedChat> {
  bool _isConnecting = false;
  bool _isServerConnected = false;

  final _msgController = TextEditingController();
  final _keyInputController = TextEditingController();
  final _nameController = TextEditingController();
  final _ipController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _msgFocusNode = FocusNode();

  final List<ChatPeer> _peers = [];
  ChatPeer? _selectedPeer;
  WebSocketChannel? _channel;
  late RSAPrivateKey _privKey;

  String _serverIp = "localhost:8080";
  String _myRawPublicKey = "";
  String _myShortId = "";
  bool _autoScroll = true;
  bool _isMobileSidebarExpanded = false;
  bool _isMessageEmpty = true;

  @override
  void initState() {
    super.initState();
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
    _msgFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _initializeWebSocket() async {
    _channel?.sink.close();

    setState(() {
      _isConnecting = true;
    });

    try {
      final channel = WebSocketChannel.connect(Uri.parse('ws://$_serverIp/ws'));
      _channel = channel;

      await channel.ready;

      setState(() {
        _isServerConnected = true;
        _isConnecting = false;
      });

      _channel!.sink.add(
        jsonEncode({
          "type": "register",
          "fromUser": _myRawPublicKey,
          "toUser": "",
          "payload": "",
        }),
      );

      _channel!.stream.listen(
        (rawData) {
          _handleIncomingPacket(rawData.toString());
        },
        onError: (err) {
          debugPrint("WebSocket connection error: $err");
          setState(() {
            _isServerConnected = false;
            _isConnecting = false;
          });
        },
        onDone: () {
          debugPrint("WebSocket channel closed by host.");
          setState(() {
            _isServerConnected = false;
            _isConnecting = false;
          });
        },
      );
    } catch (e) {
      debugPrint("Handshake failed completely: $e");
      setState(() {
        _isServerConnected = false;
        _isConnecting = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to connect to $_serverIp. Check address or server status.',
            ),
          ),
        );
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

    // Load old peers list asynchronously out of Hive storage memory
    final savedPeers = await StorageService.fetchPeerList();
    final List<ChatPeer> hydratedPeers = savedPeers.map((data) {
      return ChatPeer(data['publicKey']!, data['nickname']!);
    }).toList();

    setState(() {
      _privKey = kp.privateKey;
      _myRawPublicKey = kp.publicKey.toString().trim();
      _myShortId = _myRawPublicKey.substring(_myRawPublicKey.length - 15);
      _peers.addAll(hydratedPeers); // Restores your sidebar UI!
    });

    _initializeWebSocket();
  }

  void _handleIncomingPacket(String rawData) {
    try {
      final data = jsonDecode(rawData);
      final String senderPublicKey = data['fromUser'].toString().trim();
      final String rawCiphertext = data['payload'].toString();
      final decryptedPayload = _privKey.decrypt(rawCiphertext);
      final Map<String, dynamic> payloadMap = jsonDecode(decryptedPayload);

      if (payloadMap['isReceipt'] == true) {
        _processReadReceipt(senderPublicKey, payloadMap['msgId']);
        return;
      }

      _processIncomingMessage(senderPublicKey, rawCiphertext, payloadMap);
    } catch (_) {}
  }

  void _processReadReceipt(String senderPublicKey, String targetMsgId) {
    setState(() {
      final peer = _peers.firstWhere(
        (p) => p.rawPublicKey.trim() == senderPublicKey,
      );
      final msg = peer.messages.firstWhere((m) => m.id == targetMsgId);
      msg.isRead = true;
    });
  }

  void _processIncomingMessage(
    String senderPublicKey,
    String rawCiphertext,
    Map<String, dynamic> payloadMap,
  ) async {
    final String messageText = payloadMap['text'];
    final String msgId = payloadMap['msgId'];
    final DateTime sentTime = DateTime.parse(payloadMap['timestamp']);
    bool peerExists = _peers.any(
      (p) => p.rawPublicKey.trim() == senderPublicKey,
    );

    // Save the unpacked clear text message string. Hive ensures it is written 
    // securely encrypted with AES-256 to your physical disk.
    await StorageService.persistEncryptedMessage(
      peerPublicKey: senderPublicKey,
      msgId: msgId,
      encryptedPayload: messageText, // Save clear text to let Hive encrypt it uniformly
      isMe: false,
      timestampIso: sentTime.toIso8601String(),
    );

    if (peerExists) {
      setState(() {
        final sender = _peers.firstWhere(
          (p) => p.rawPublicKey.trim() == senderPublicKey,
        );
        if (!sender.messages.any((m) => m.id == msgId)) {
          sender.messages.add(
            ChatMessage(
              messageText,
              false,
              customTime: sentTime,
              customId: msgId,
            ),
          );
        }
        if (_selectedPeer == sender) {
          _sendReadReceipt(senderPublicKey, msgId);
        }
      });
      _scrollToBottom();
    } else {
      if (!mounted) return;
      Dialogs.showUnknownPeerDialog(
        context: context,
        senderPublicKey: senderPublicKey,
        initialMessage: messageText,
        msgId: msgId,
        arrivalTime: sentTime,
        onAccept: (nickname, acceptedMsgId, acceptedTime) {
          setState(() {
            final newPeer = ChatPeer(senderPublicKey, nickname);
            newPeer.messages.add(
              ChatMessage(
                messageText,
                false,
                customTime: acceptedTime,
                customId: acceptedMsgId,
              ),
            );
            _peers.add(newPeer);
            _selectedPeer ??= newPeer;
            _sendReadReceipt(senderPublicKey, acceptedMsgId);
          });
          _syncPeersToStorage();
          _scrollToBottom();
        },
      );
    }
  }

  void _sendReadReceipt(String targetKey, String messageId) {
    if (_channel == null) return;
    final recipientPublicKeyObj = RSAPublicKey.fromString(targetKey.trim());
    final receiptPayload = jsonEncode({"isReceipt": true, "msgId": messageId});

    _channel!.sink.add(
      jsonEncode({
        "type": "message",
        "fromUser": _myRawPublicKey,
        "toUser": targetKey.trim(),
        "payload": recipientPublicKeyObj.encrypt(receiptPayload),
      }),
    );
  }

  void _handleConnectNewPeer(String nickname, String key) {
    bool alreadyExists = _peers.any((p) => p.rawPublicKey.trim() == key);
    if (alreadyExists) {
      setState(() {
        _selectedPeer = _peers.firstWhere((p) => p.rawPublicKey.trim() == key);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Chat with this key already exists! Switching to chat.',
          ),
        ),
      );
    } else {
      setState(() => _peers.add(ChatPeer(key, nickname)));
      _selectedPeer ??= _peers.last;
      _syncPeersToStorage();
    }
    _keyInputController.clear();
    _nameController.clear();
  }

  void _sendMessage() async {
    if (_msgController.text.isEmpty ||
        _selectedPeer == null ||
        _channel == null) {
      return;
    }

    final text = _msgController.text;
    final newMsg = ChatMessage(text, true);
    final recipientPublicKeyObj = RSAPublicKey.fromString(
      _selectedPeer!.rawPublicKey.trim(),
    );

    final messagePayload = jsonEncode({
      "isReceipt": false,
      "text": text,
      "msgId": newMsg.id,
      "timestamp": newMsg.timestamp.toIso8601String(),
    });

    // 1. Encrypt using the recipient's key ONLY for the network pipe transmission
    final encryptedPayloadString = recipientPublicKeyObj.encrypt(messagePayload);

    _channel!.sink.add(
      jsonEncode({
        "type": "message",
        "fromUser": _myRawPublicKey,
        "toUser": _selectedPeer!.rawPublicKey.trim(),
        "payload": encryptedPayloadString,
      }),
    );

    // 2. Persist our local copy safely inside the AES Hive file as a clean inner string.
    // This removes the RSA decryption conflict since it doesn't store the peer's cipher.
    await StorageService.persistEncryptedMessage(
      peerPublicKey: _selectedPeer!.rawPublicKey.trim(),
      msgId: newMsg.id,
      encryptedPayload: text, // Pass the clear text directly (Hive encrypts this on disk automatically)
      isMe: true,
      timestampIso: newMsg.timestamp.toIso8601String(),
    );

    setState(() {
      _selectedPeer!.messages.add(newMsg);
    });

    _msgController.clear();
    _scrollToBottom();
    _msgFocusNode.requestFocus();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
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
              Text('Copy Message'),
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
    ).then((selectedValue) {
      if (selectedValue == 'copy') {
        Clipboard.setData(ClipboardData(text: message.text));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message copied to clipboard'),
            duration: Duration(seconds: 1),
          ),
        );
      } else if (selectedValue == 'delete') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Delete clicked (Placeholder active)')),
        );
      }
    });
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Network Target',
              style: TextStyle(
                fontSize: 12,
                color: Colors.tealAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                hintText: "e.g. 192.168.1.50:8080",
                labelText: "Server Address",
              ),
            ),
            const SizedBox(height: 12),
            const Divider(color: Colors.white10),
            const SizedBox(height: 12),
            const Text(
              'Danger Zone',
              style: TextStyle(
                fontSize: 12,
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent, width: 0.5),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text(
                  'Reset Identity',
                  style: TextStyle(fontSize: 13),
                ),
                onPressed: () {
                  Navigator.pop(ctx);

                  showDialog(
                    context: context,
                    builder: (confirmCtx) => AlertDialog(
                      title: const Text('Are you absolutely sure?'),
                      content: const Text(
                        'This actions destroys your identity permanently. '
                        'Your old peers will no longer be able to read your incoming payloads.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(confirmCtx),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                          ),
                          onPressed: () {
                            Navigator.pop(confirmCtx);
                            _resetIdentity();
                          },
                          child: const Text(
                            'Wipe & Re-key',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (_ipController.text.isNotEmpty) {
                setState(() {
                  _serverIp = _ipController.text.trim();
                });
                _initializeWebSocket();
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Reconnecting secure pipe to: $_serverIp'),
                  ),
                );
              }
            },
            child: const Text('Save & Connect'),
          ),
        ],
      ),
    );
  }

  void _resetIdentity() async {
    final kp = RSAKeypair.fromRandom();
    await StorageService.savePrivateKey(kp.privateKey.toString());

    setState(() {
      _privKey = kp.privateKey;
      _myRawPublicKey = kp.publicKey.toString().trim();
      _myShortId = _myRawPublicKey.substring(_myRawPublicKey.length - 15);
      _peers.clear();
      _selectedPeer = null;
      _isServerConnected = false;
    });

    _initializeWebSocket();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Identity cleared. New secure key pairs deployed.'),
        ),
      );
    }
  }

  void _connectToTargetServer() {
    if (_ipController.text.isNotEmpty) {
      setState(() {
        _serverIp = _ipController.text.trim();
      });
      _initializeWebSocket();
    }
  }

  Widget _buildConnectionSetupScreen() {
    return Scaffold(
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.waving_hand_rounded,
                size: 64,
                color: Colors.tealAccent,
              ),
              const SizedBox(height: 24),
              const Text(
                'Welcome to Morse Messenger!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter the address of a relay server to start chatting privately and anonymously.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white30, fontSize: 13),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _ipController,
                decoration: const InputDecoration(
                  hintText: "e.g. 192.168.1.50:8080",
                  labelText: "Server Address",
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _connectToTargetServer(),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.tealAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: _isConnecting ? null : _connectToTargetServer,
                child: _isConnecting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text('Connect & Enter Morse'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFullSidebarContent() {
    return Column(
      children: [
        SizedBox(
          height: 73,
          child: Center(
            child: ListTile(
              title: const Text(
                'Morse Messenger',
                style: TextStyle(
                  fontWeight: FontWeight.w400,
                  fontFamily: "monospace",
                ),
              ),
              trailing: IconButton(
                icon: const Icon(
                  Icons.add_circle_outline,
                  color: Colors.tealAccent,
                ),
                onPressed: () => Dialogs.showAddPeer(
                  context: context,
                  nameController: _nameController,
                  keyInputController: _keyInputController,
                  onConnect: _handleConnectNewPeer,
                ),
              ),
            ),
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 10.0),
            children: _peers.map((p) => _buildPeerListTile(p)).toList(),
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        _buildSidebarFooterActions(),
      ],
    );
  }

  void _syncPeersToStorage() async {
    final serialized = _peers.map((p) => {
      "nickname": p.nickname,
      "publicKey": p.rawPublicKey
    }).toList();
    await StorageService.savePeerList(serialized);
  }

  Widget _buildPeerListTile(ChatPeer p) {
    return ListTile(
      selected: _selectedPeer == p,
      selectedTileColor: Colors.white10,
      leading: CircleAvatar(
        backgroundColor: Colors.tealAccent.withValues(alpha: 0.1),
        child: Text(
          p.nickname[0].toUpperCase(),
          style: const TextStyle(color: Colors.tealAccent),
        ),
      ),
      title: Text(p.nickname),
      onTap: () async {
        final records = await StorageService.fetchHistory(p.rawPublicKey);
        
        List<ChatMessage> loadedMessages = [];
        for (var record in records) {
          // The payload field now holds the clean message text directly out of the AES file
          final String messageText = record['payload'] ?? '';
          
          loadedMessages.add(
            ChatMessage(
              messageText,
              record['isMe'] == true,
              customTime: DateTime.parse(record['timestamp']),
              customId: record['id'],
            )..isRead = record['isRead'] == true,
          );
        }

        setState(() {
          p.messages = loadedMessages; 
          _selectedPeer = p;
          _isMobileSidebarExpanded = false;
          _autoScroll = true;
        });
        
        _scrollToBottom();
        
        for (var m in p.messages) {
          if (!m.isMe && !m.isRead) {
            _sendReadReceipt(p.rawPublicKey, m.id);
            m.isRead = true;
          }
        }
      },
    );
  }

  Widget _buildSidebarFooterActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.tealAccent,
                side: const BorderSide(color: Colors.white10),
              ),
              icon: const Icon(Icons.vpn_key, size: 14),
              label: const Text('Identity', style: TextStyle(fontSize: 11)),
              onPressed: () => Dialogs.showIdentityModal(
                context: context,
                shortId: _myShortId,
                rawPublicKey: _myRawPublicKey,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            style: IconButton.styleFrom(
              side: const BorderSide(color: Colors.white10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            icon: const Icon(Icons.settings, color: Colors.white70, size: 18),
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildMobileCompactSidebar() {
    return Container(
      width: 68,
      color: const Color(0xFF1A1A1A),
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 73,
              child: Center(
                child: IconButton(
                  icon: const Icon(Icons.menu, color: Colors.tealAccent),
                  onPressed: () =>
                      setState(() => _isMobileSidebarExpanded = true),
                ),
              ),
            ),
            const Divider(color: Colors.white10, height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 10.0),
                children: _peers
                    .map((p) => _buildMobileAvatarButton(p))
                    .toList(),
              ),
            ),
            const Divider(color: Colors.white10, height: 1),
            _buildMobileCompactFooterActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileAvatarButton(ChatPeer p) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: GestureDetector(
        onTap: () async {
          final records = await StorageService.fetchHistory(p.rawPublicKey);
          List<ChatMessage> loadedMessages = [];
          for (var record in records) {
            try {
              final decryptedPayload = _privKey.decrypt(record['payload']);
              final Map<String, dynamic> payloadMap = jsonDecode(decryptedPayload);
              loadedMessages.add(
                ChatMessage(
                  payloadMap['text'] ?? '',
                  record['isMe'] == true,
                  customTime: DateTime.parse(record['timestamp']),
                  customId: record['id'],
                )..isRead = record['isRead'] == true,
              );
            } catch (_) {
              loadedMessages.add(
                ChatMessage(
                  "[Undecryptable payload]",
                  record['isMe'] == true,
                  customTime: DateTime.parse(record['timestamp']),
                  customId: record['id'],
                ),
              );
            }
          }

          setState(() {
            p.messages = loadedMessages;
            _selectedPeer = p;
            _autoScroll = true;
          });
          _scrollToBottom();
        },
        child: CircleAvatar(
          radius: 20,
          backgroundColor: _selectedPeer == p
              ? Colors.tealAccent
              : Colors.white10,
          child: Text(
            p.nickname[0].toUpperCase(),
            style: TextStyle(
              color: _selectedPeer == p ? Colors.black : Colors.tealAccent,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileCompactFooterActions() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white30, size: 20),
            onPressed: _showSettingsDialog,
          ),
          const SizedBox(height: 8),
          IconButton(
            icon: const Icon(Icons.vpn_key, color: Colors.white30, size: 20),
            onPressed: () => Dialogs.showIdentityModal(
              context: context,
              shortId: _myShortId,
              rawPublicKey: _myRawPublicKey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContentSection() {
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
            _buildChatHeader(),
            const Divider(height: 1, color: Colors.white10),
            _buildMessageStreamArea(),
            _buildMessageInputField(),
          ],
        ),
      ),
    );
  }

  Widget _buildChatHeader() {
    return SizedBox(
      height: 73,
      child: Center(
        child: ListTile(
          title: Text(
            _selectedPeer!.nickname,
            style: const TextStyle(
              color: Colors.tealAccent,
              fontWeight: FontWeight.bold,
            ),
          ),
          subtitle: Text(
            'Target: ${_selectedPeer!.shortId}',
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageStreamArea() {
    return Expanded(
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          final isAtBottom =
              scrollInfo.metrics.pixels >=
              (scrollInfo.metrics.maxScrollExtent - 10);
          if (isAtBottom && !_autoScroll) {
            _autoScroll = true;
          } else if (!isAtBottom && _autoScroll) {
            _autoScroll = false;
          }
          return true;
        },
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(24),
          children: _selectedPeer!.messages
              .map((m) => _buildMessageBubble(m))
              .toList(),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage m) {
    final String timeString =
        "${m.timestamp.hour.toString().padLeft(2, '0')}:${m.timestamp.minute.toString().padLeft(2, '0')}";
    TapDownDetails? tapDetails;

    return Align(
      alignment: m.isMe ? Alignment.centerRight : Alignment.centerLeft,
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
              child: Text(m.text),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              m.isMe ? "$timeString ${m.isRead ? '✓✓' : '✓'}" : timeString,
              style: const TextStyle(fontSize: 10, color: Colors.white30),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageInputField() {
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
              decoration: const InputDecoration(
                hintText: 'Type your message...',
                filled: true,
                fillColor: Color(0xFF1E1E1E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FloatingActionButton(
            backgroundColor: _isMessageEmpty
                ? Colors.white30
                : Colors.tealAccent,
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
              color: const Color(0xFF1A1A1A),
              child: _buildFullSidebarContent(),
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

    if (!_isServerConnected) {
      return _buildConnectionSetupScreen();
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
                      color: const Color(0xFF1A1A1A),
                      child: SafeArea(child: _buildFullSidebarContent()),
                    )
                  else
                    _buildMobileCompactSidebar(),
                  _buildMainContentSection(),
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