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
      final dec = _privKey.decrypt(data['payload']); 

      bool peerExists = _peers.any((p) => p.rawPublicKey.trim() == senderPublicKey);

      if (peerExists) {
        setState(() {
          final sender = _peers.firstWhere((p) => p.rawPublicKey.trim() == senderPublicKey);
          sender.messages.add(ChatMessage(dec, false));
        });
      } else {
        Dialogs.showUnknownPeerDialog(
          context: context,
          senderPublicKey: senderPublicKey,
          initialMessage: dec,
          onAccept: (nickname) {
            setState(() {
              final newPeer = ChatPeer(senderPublicKey, nickname);
              newPeer.messages.add(ChatMessage(dec, false));
              _peers.add(newPeer);
              _selectedPeer ??= newPeer;
            });
          },
        );
      }
    } catch (_) {}
  }

  void _handleConnectNewPeer(String nickname, String key) {
    // Verify if the public key already exists in our chat tracker
    bool alreadyExists = _peers.any((p) => p.rawPublicKey.trim() == key);
    
    if (alreadyExists) {
      setState(() {
        _selectedPeer = _peers.firstWhere((p) => p.rawPublicKey.trim() == key);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat with this key already exists! Switching to chat.')),
      );
    } else {
      setState(() => _peers.add(ChatPeer(key, nickname)));
      _selectedPeer ??= _peers.last;
    }
    _keyInputController.clear(); 
    _nameController.clear();
  }

  void _sendMessage() {
    if (_msgController.text.isNotEmpty && _selectedPeer != null) {
      final text = _msgController.text;
      final recipientPublicKeyObj = RSAPublicKey.fromString(_selectedPeer!.rawPublicKey.trim());
      final enc = recipientPublicKeyObj.encrypt(text);
      
      _channel.sink.add(jsonEncode({
        "type": "message", 
        "fromUser": _myRawPublicKey, 
        "toUser": _selectedPeer!.rawPublicKey.trim(), 
        "payload": enc
      }));
      
      setState(() { _selectedPeer!.messages.add(ChatMessage(text, true)); });
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
                  onTap: () => setState(() => _selectedPeer = p),
                )).toList())),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.tealAccent, side: const BorderSide(color: Colors.white10)),
                      icon: const Icon(Icons.vpn_key, size: 16),
                      label: const Text('Show Identity Key', style: TextStyle(fontSize: 12)),
                      onPressed: () => Dialogs.showIdentityModal(
                        context: context, 
                        shortId: _myShortId, 
                        rawPublicKey: _myRawPublicKey,
                      ),
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
                        children: _selectedPeer!.messages.map((m) => Align(
                          alignment: m.isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4), 
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: m.isMe ? const Color(0xFF0B0B0B) : const Color(0xFF1E1E1E), 
                              borderRadius: BorderRadius.circular(12),
                              border: m.isMe ? Border.all(color: Colors.white10, width: 0.5) : null
                            ),
                            child: Text(m.text),
                          ),
                        )).toList(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _msgController, 
                            decoration: const InputDecoration(
                              hintText: 'Type your message...', // Perfectly updated custom prompt string
                              filled: true, 
                              fillColor: Color(0xFF1E1E1E), 
                              border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide.none),
                            ),
                          ),
                        ),
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