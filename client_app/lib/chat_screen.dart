import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypton/crypton.dart';
import 'models.dart';
import 'dialogs.dart';

class DecentralizedChat extends StatefulWidget {
  const DecentralizedChat({super.key});
  @override
  State<DecentralizedChat> createState() => _DecentralizedChatState();
}

class _DecentralizedChatState extends State<DecentralizedChat> {
  final _msgController = TextEditingController(), _keyInputController = TextEditingController(), _nameController = TextEditingController();
  final _channel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080/ws'));
  late RSAPrivateKey _privKey;
  String _myRawPublicKey = "";
  String _myShortId = "";
  final List<ChatPeer> _peers = [];
  ChatPeer? _selectedPeer;

  @override
  void initState() {
    super.initState();
    final kp = RSAKeypair.fromRandom();
    _privKey = kp.privateKey;
    _myRawPublicKey = kp.publicKey.toString().trim();
    _myShortId = _myRawPublicKey.substring(_myRawPublicKey.length - 15);
    
    _channel.sink.add(jsonEncode({"type": "register", "fromUser": _myRawPublicKey, "toUser": "", "payload": ""}));

    _channel.stream.listen((rawData) {
      _handleIncomingPacket(rawData.toString());
    });
  }

  void _handleIncomingPacket(String rawData) {
    try {
      final data = jsonDecode(rawData);
      final String senderPublicKey = data['fromUser'].toString().trim();
      
      // Decrypt the core wrapper
      final decryptedPayload = _privKey.decrypt(data['payload']);
      final Map<String, dynamic> payloadMap = jsonDecode(decryptedPayload);

      // 1. Process receipt notifications
      if (payloadMap['isReceipt'] == true) {
        final String targetMsgId = payloadMap['msgId'];
        setState(() {
          final peer = _peers.firstWhere((p) => p.rawPublicKey.trim() == senderPublicKey);
          final msg = peer.messages.firstWhere((m) => m.id == targetMsgId);
          msg.isRead = true;
        });
        return;
      }

      // 2. Process text messages using the sender's absolute original timestamp
      final String messageText = payloadMap['text'];
      final String msgId = payloadMap['msgId'];
      final DateTime sentTime = DateTime.parse(payloadMap['timestamp']);

      bool peerExists = _peers.any((p) => p.rawPublicKey.trim() == senderPublicKey);

      if (peerExists) {
        setState(() {
          final sender = _peers.firstWhere((p) => p.rawPublicKey.trim() == senderPublicKey);
          if (!sender.messages.any((m) => m.id == msgId)) {
            sender.messages.add(ChatMessage(messageText, false, customTime: sentTime, customId: msgId));
          }
          if (_selectedPeer == sender) {
            _sendReadReceipt(senderPublicKey, msgId);
          }
        });
      } else {
        Dialogs.showUnknownPeerDialog(
          context: context,
          senderPublicKey: senderPublicKey,
          initialMessage: messageText,
          msgId: msgId,
          arrivalTime: sentTime,
          onAccept: (nickname, acceptedMsgId, acceptedTime) {
            setState(() {
              final newPeer = ChatPeer(senderPublicKey, nickname);
              newPeer.messages.add(ChatMessage(messageText, false, customTime: acceptedTime, customId: acceptedMsgId));
              _peers.add(newPeer);
              _selectedPeer ??= newPeer;
              _sendReadReceipt(senderPublicKey, acceptedMsgId);
            });
          },
        );
      }
    } catch (_) {}
  }

  void _sendReadReceipt(String targetKey, String messageId) {
    final recipientPublicKeyObj = RSAPublicKey.fromString(targetKey.trim());
    
    // Package receipt data inside the encrypted channel stream payload
    final receiptPayload = jsonEncode({
      "isReceipt": true,
      "msgId": messageId,
    });
    
    _channel.sink.add(jsonEncode({
      "type": "message",
      "fromUser": _myRawPublicKey,
      "toUser": targetKey.trim(),
      "payload": recipientPublicKeyObj.encrypt(receiptPayload)
    }));
  }

  void _handleConnectNewPeer(String nickname, String key) {
    bool alreadyExists = _peers.any((p) => p.rawPublicKey.trim() == key);
    if (alreadyExists) {
      setState(() { _selectedPeer = _peers.firstWhere((p) => p.rawPublicKey.trim() == key); });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chat with this key already exists! Switching to chat.')));
    } else {
      setState(() => _peers.add(ChatPeer(key, nickname)));
      _selectedPeer ??= _peers.last;
    }
    _keyInputController.clear(); _nameController.clear();
  }

  void _sendMessage() {
    if (_msgController.text.isNotEmpty && _selectedPeer != null) {
      final text = _msgController.text;
      final newMsg = ChatMessage(text, true);
      
      final recipientPublicKeyObj = RSAPublicKey.fromString(_selectedPeer!.rawPublicKey.trim());
      
      // Bundle text and metadata into a secure payload map before asymmetric encrypting
      final messagePayload = jsonEncode({
        "isReceipt": false,
        "text": text,
        "msgId": newMsg.id,
        "timestamp": newMsg.timestamp.toIso8601String(),
      });

      _channel.sink.add(jsonEncode({
        "type": "message", 
        "fromUser": _myRawPublicKey, 
        "toUser": _selectedPeer!.rawPublicKey.trim(), 
        "payload": recipientPublicKeyObj.encrypt(messagePayload)
      }));
      
      setState(() { _selectedPeer!.messages.add(newMsg); });
      _msgController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_myRawPublicKey.isEmpty) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 260, color: const Color(0xFF1A1A1A),
            child: SafeArea(
              child: Column(children: [
                SizedBox(
                  height: 72,
                  child: Center(
                    child: ListTile(
                      title: const Text('Morse Messenger', style: TextStyle(fontWeight: FontWeight.bold)),
                      trailing: IconButton(
                        icon: const Icon(Icons.add_circle_outline, color: Colors.tealAccent), 
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
                Expanded(child: ListView(children: _peers.map((p) => ListTile(
                  selected: _selectedPeer == p, selectedTileColor: Colors.white10,
                  leading: CircleAvatar(backgroundColor: Colors.tealAccent.withOpacity(0.1), child: Text(p.nickname[0].toUpperCase(), style: const TextStyle(color: Colors.tealAccent))),
                  title: Text(p.nickname),
                  onTap: () {
                    setState(() => _selectedPeer = p);
                    for (var m in p.messages) {
                      if (!m.isMe && !m.isRead) {
                        _sendReadReceipt(p.rawPublicKey, m.id);
                        m.isRead = true;
                      }
                    }
                  },
                )).toList())),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.tealAccent, side: const BorderSide(color: Colors.white10)),
                      icon: const Icon(Icons.vpn_key, size: 16),
                      label: const Text('Show Identity Key', style: TextStyle(fontSize: 12)),
                      onPressed: () => Dialogs.showIdentityModal(context: context, shortId: _myShortId, rawPublicKey: _myRawPublicKey),
                    ),
                  ),
                )
              ]),
            ),
          ),
          Expanded(
            child: _selectedPeer == null
              ? const Center(child: Text('No Active Secure Selection', style: TextStyle(color: Colors.white30)))
              : SafeArea(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(
                      height: 72,
                      child: Center(
                        child: ListTile(
                          title: Text(_selectedPeer!.nickname, style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)), 
                          subtitle: Text('Target: ${_selectedPeer!.shortId}', style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white10),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(24),
                        children: _selectedPeer!.messages.map((m) {
                          final String timeString = "${m.timestamp.hour.toString().padLeft(2, '0')}:${m.timestamp.minute.toString().padLeft(2, '0')}";
                          return Align(
                            alignment: m.isMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: Column(
                              crossAxisAlignment: m.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                Container(
                                  margin: const EdgeInsets.symmetric(vertical: 4), 
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: m.isMe ? const Color(0xFF0B0B0B) : const Color(0xFF1E1E1E), 
                                    borderRadius: BorderRadius.circular(12),
                                    border: m.isMe ? Border.all(color: Colors.white10, width: 0.5) : null
                                  ),
                                  child: Text(m.text),
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
                        }).toList(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Row(children: [
                        Expanded(child: TextField(controller: _msgController, decoration: const InputDecoration(hintText: 'Type your message...', filled: true, fillColor: Color(0xFF1E1E1E), border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide.none)))),
                        const SizedBox(width: 12),
                        FloatingActionButton(backgroundColor: Colors.tealAccent, onPressed: _sendMessage, child: const Icon(Icons.lock, color: Colors.black)),
                      ]),
                    )
                  ]),
                ),
          )
        ],
      ),
    );
  }
}