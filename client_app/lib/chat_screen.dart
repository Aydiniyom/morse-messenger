import 'dart:convert';
import 'package:client_app/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypton/crypton.dart';
import 'models.dart';
import 'dialogs.dart';
import 'storage_service.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:encrypt/encrypt.dart' as enc;

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

  final Set<String> _onlinePeers = {};

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
      // Cleanly parse out the scheme without losing any explicit pathing suffixes if provided
      final wsUrl =
          _serverIp.startsWith("ws://") || _serverIp.startsWith("wss://")
          ? _serverIp
          : _serverIp.endsWith('/ws')
          ? "ws://$_serverIp"
          : "ws://$_serverIp/ws";

      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _channel = channel;

      await channel.ready;

      setState(() {
        _isServerConnected = true;
        _isConnecting = false;
      });

      // --- PERSIST THE IP ADDRESS THE SECOND CONNECTION IS VERIFIED ---
      StorageService.saveServerIp(_serverIp);

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

    // 1. Fetch saved contacts list
    final savedPeers = await StorageService.fetchPeerList();
    final List<ChatPeer> hydratedPeers = savedPeers.map((data) {
      return ChatPeer(data['publicKey']!, data['nickname']!);
    }).toList();

    // 2. Fetch the saved Server IP address from Hive
    final String? savedIp = await StorageService.fetchServerIp();

    setState(() {
      _privKey = kp.privateKey;
      _myRawPublicKey = kp.publicKey.toString().trim();
      _myShortId = _myRawPublicKey.substring(_myRawPublicKey.length - 15);
      _peers.addAll(hydratedPeers);

      // 3. If an IP was saved before, override the default "localhost:8080"
      if (savedIp != null && savedIp.isNotEmpty) {
        _serverIp = savedIp;
        _ipController.text = savedIp;
      }
    });

    _initializeWebSocket();
  }

  void _handleIncomingPacket(String rawData) {
    try {
      final data = jsonDecode(rawData);
      final String senderPublicKey = data['fromUser'].toString().trim();
      final String rawPayload = data['payload'].toString();
      final String packetType = data['type'] ?? '';

      // --- HANDLE STATUS UPDATES ---
      if (packetType == 'status_update') {
        setState(() {
          if (senderPublicKey == 'server') {
            // The initial bulk list sent during registration
            final List<dynamic> currentOnlineList = jsonDecode(data['payload']);
            _onlinePeers.addAll(
              currentOnlineList.map((e) => e.toString().trim()),
            );
          } else {
            // A dynamic single peer status change alert
            final String status = data['payload'];
            if (status == 'online') {
              _onlinePeers.add(senderPublicKey);
            } else {
              _onlinePeers.remove(senderPublicKey);
            }
          }
        });
        return; // Stop processing further (it's not a chat message)
      }
      // 1. Try decrypting the payload directly with RSA first.
      // If it's a read receipt or an old format message, this will succeed.
      String decryptedPayloadString;
      Map<String, dynamic>? parsedPayloadMap;
      bool isHybridPacket = false;

      try {
        decryptedPayloadString = _privKey.decrypt(rawPayload);
        parsedPayloadMap = jsonDecode(decryptedPayloadString);
      } catch (_) {
        // If pure RSA decryption fails, it means the payload is a hybrid JSON bundle structure!
        isHybridPacket = true;
      }

      // 2. Handle standard Hybrid packet processing if flag is set
      if (isHybridPacket) {
        final Map<String, dynamic> hybridBundle = jsonDecode(rawPayload);
        final String rsaEncryptedKeyBundle = hybridBundle['encryptedAesKey'];
        final String base64Ciphertext = hybridBundle['ciphertext'];

        // Decrypt the AES key bundle via RSA
        final decryptedKeyBundleString = _privKey.decrypt(
          rsaEncryptedKeyBundle,
        );
        final Map<String, dynamic> keyBundleMap = jsonDecode(
          decryptedKeyBundleString,
        );

        final aesKey = enc.Key.fromBase64(keyBundleMap['key']);
        final iv = enc.IV.fromBase64(keyBundleMap['iv']);

        // Decrypt the actual message text via AES
        final encrypter = enc.Encrypter(enc.AES(aesKey, mode: enc.AESMode.cbc));
        final decryptedMessageTextPayload = encrypter.decrypt64(
          base64Ciphertext,
          iv: iv,
        );

        parsedPayloadMap = jsonDecode(decryptedMessageTextPayload);
      }

      if (parsedPayloadMap == null) return;

      // 3. Routinely split execution between receipts and regular text payloads
      if (parsedPayloadMap['isReceipt'] == true) {
        _processReadReceipt(senderPublicKey, parsedPayloadMap['msgId']);
        return;
      }

      // Send the clean, unpacked message text string down to persistence
      _processIncomingMessage(
        senderPublicKey,
        parsedPayloadMap['text'] ?? '',
        parsedPayloadMap,
      );
    } catch (e) {
      debugPrint("Hybrid decryption failed payload processing execution: $e");
    }
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
      encryptedPayload:
          messageText, // Save clear text to let Hive encrypt it uniformly
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
        } else {
          NotificationService.showNotification(
            id: DateTime.now().millisecondsSinceEpoch ~/ 1000, // Safe unique ID
            title: "New Message from ${sender.nickname}",
            body: messageText,
          );
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

    // 1. Prepare our clean cleartext message structural wrapper
    final innerMessagePayload = jsonEncode({
      "isReceipt": false,
      "text": text,
      "msgId": newMsg.id,
      "timestamp": newMsg.timestamp.toIso8601String(),
    });

    // 2. HYBRID LAYER: Generate an ephemeral 256-bit AES key and a secure IV
    final ephemeralAesKey = enc.Key.fromSecureRandom(32);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(
      enc.AES(ephemeralAesKey, mode: enc.AESMode.cbc),
    );

    // 3. Encrypt the unlimited length message string using AES
    final encryptedCiphertext = encrypter.encrypt(innerMessagePayload, iv: iv);

    // 4. Encrypt the tiny 32-byte AES key using the target's asymmetric RSA Public Key
    // We combine the raw key bytes and IV bytes so everything travels together securely.
    final keyBundleToEncrypt = jsonEncode({
      "key": ephemeralAesKey.base64,
      "iv": iv.base64,
    });
    final rsaEncryptedKeyBundle = recipientPublicKeyObj.encrypt(
      keyBundleToEncrypt,
    );

    // 5. Package the hybrid payload bundle for the network pipe
    final structuralNetworkPacket = jsonEncode({
      "encryptedAesKey": rsaEncryptedKeyBundle,
      "ciphertext": encryptedCiphertext.base64,
    });

    _channel!.sink.add(
      jsonEncode({
        "type": "message",
        "fromUser": _myRawPublicKey,
        "toUser": _selectedPeer!.rawPublicKey.trim(),
        "payload": structuralNetworkPacket, // Send the hybrid bundle
      }),
    );

    // 6. Persist local copy securely inside our AES Hive file
    await StorageService.persistEncryptedMessage(
      peerPublicKey: _selectedPeer!.rawPublicKey.trim(),
      msgId: newMsg.id,
      encryptedPayload: text,
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

  void _jumpToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
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
    final serialized = _peers
        .map((p) => {"nickname": p.nickname, "publicKey": p.rawPublicKey})
        .toList();
    await StorageService.savePeerList(serialized);
  }

  Future<void> _selectAndLoadPeer(ChatPeer p) async {
    // 1. Fetch historical database records uniformly
    final records = await StorageService.fetchHistory(p.rawPublicKey);

    List<ChatMessage> loadedMessages = [];
    for (var record in records) {
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

    // 2. Set the state variables for the entire UI
    setState(() {
      p.messages = loadedMessages;
      _selectedPeer = p;
      _isMobileSidebarExpanded =
          false; // Automatically closes the drawer if it was open on mobile
      _autoScroll = true;
    });

    // 3. Trigger the instant jump to the bottom of the stream
    _jumpToBottom();

    // 4. Send read receipts for incoming unread messages now that they are viewed
    for (var m in p.messages) {
      if (!m.isMe && !m.isRead) {
        _sendReadReceipt(p.rawPublicKey, m.id);
        m.isRead = true;
      }
    }
  }

  Widget _buildPeerListTile(ChatPeer p) {
    final bool isOnline = _onlinePeers.contains(p.rawPublicKey.trim());

    return ListTile(
      selected: _selectedPeer == p,
      selectedTileColor: Colors.white10,
      leading: Stack(
        children: [
          CircleAvatar(
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
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: isOnline ? Colors.greenAccent : Colors.blueGrey,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF1A1A1A), width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Text(p.nickname),
      onTap: () => _selectAndLoadPeer(p),
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
    final bool isOnline = _onlinePeers.contains(p.rawPublicKey.trim());

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: GestureDetector(
        onTap: () => _selectAndLoadPeer(p),
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircleAvatar(
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
            Positioned(
              right: 14,
              bottom: 2,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: isOnline ? Colors.greenAccent : Colors.blueGrey,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF1A1A1A), width: 2),
                ),
              ),
            ),
          ],
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
      child: TweenAnimationBuilder<double>(
        // Unique key per message prevents the animation from re-triggering when you scroll
        key: ValueKey(m.id),
        tween: Tween<double>(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          return Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(0, 20 * (1.0 - value)),
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
                child: MarkdownBody(
                  data: m.text,
                  selectable: false,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                        p: const TextStyle(color: Colors.white, fontSize: 14),
                        code: const TextStyle(
                          backgroundColor: Colors.black26,
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.tealAccent,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: Colors.black38,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white10, width: 0.5),
                        ),
                        a: const TextStyle(
                          color: Colors.tealAccent,
                          decoration: TextDecoration.underline,
                        ),
                        listBullet: const TextStyle(color: Colors.tealAccent),
                        blockquoteDecoration: BoxDecoration(
                          color: Colors.teal,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                ),
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
