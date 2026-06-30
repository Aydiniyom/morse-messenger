import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypton/crypton.dart';

void main() => runApp(MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF121212), primaryColor: Colors.tealAccent),
  home: const DecentralizedChat(),
));

class ChatPeer {
  final String fingerprint;
  final String rawPublicKey; // Store their actual public key to encrypt replies!
  String nickname;
  List<String> messages = [];
  ChatPeer(this.fingerprint, this.rawPublicKey, this.nickname);
}

class DecentralizedChat extends StatefulWidget {
  const DecentralizedChat({super.key});
  @override
  State<DecentralizedChat> createState() => _DecentralizedChatState();
}

class _DecentralizedChatState extends State<DecentralizedChat> {
  final _msgController = TextEditingController(), _fpController = TextEditingController(), _nameController = TextEditingController();
  final _channel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080/ws'));
  late RSAPrivateKey _privKey;
  late String _myFullPublicKeyString;
  String _myFingerprint = "";
  final List<ChatPeer> _peers = [];
  ChatPeer? _selectedPeer;

  @override
  void initState() {
    super.initState();
    final kp = RSAKeypair.fromRandom();
    _privKey = kp.privateKey;
    _myFullPublicKeyString = kp.publicKey.toString();
    _myFingerprint = _myFullPublicKeyString.substring(_myFullPublicKeyString.length - 30);
    
    _channel.sink.add(jsonEncode({"type": "register", "fromUser": _myFingerprint, "toUser": "", "payload": ""}));
  }

  void _showUnknownPeerDialog(String senderFp, String senderPublicKey, String decryptedMessage) {
    final TextEditingController incomingNameController = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Incoming Connection', style: TextStyle(color: Colors.tealAccent)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('From ID: $senderFp', style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white54)),
            const SizedBox(height: 16),
            TextField(controller: incomingNameController, decoration: const InputDecoration(hintText: "Assign a Nickname")),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
            onPressed: () {
              if (incomingNameController.text.isNotEmpty) {
                setState(() {
                  final newPeer = ChatPeer(senderFp, senderPublicKey, incomingNameController.text.trim());
                  newPeer.messages.add("${incomingNameController.text}: $decryptedMessage");
                  _peers.add(newPeer);
                  _selectedPeer ??= newPeer;
                });
                Navigator.pop(ctx);
              }
            },
            child: const Text('Accept & Add', style: TextStyle(color: Colors.black)),
          )
        ],
      ),
    );
  }

  void _showAddPeer() => showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text('Add Peer Node', style: TextStyle(color: Colors.tealAccent)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _nameController, decoration: const InputDecoration(hintText: "Nickname")),
        TextField(controller: _fpController, decoration: const InputDecoration(hintText: "Fingerprint ID")),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
          onPressed: () {
            if (_fpController.text.isNotEmpty && _nameController.text.isNotEmpty) {
              setState(() => _peers.add(ChatPeer(_fpController.text.trim(), "", _nameController.text.trim())));
              _selectedPeer ??= _peers.last;
              _fpController.clear(); _nameController.clear();
              Navigator.pop(ctx);
            }
          },
          child: const Text('Connect', style: TextStyle(color: Colors.black)),
        )
      ],
    ),
  );

  void _sendMessage() {
    if (_msgController.text.isNotEmpty && _selectedPeer != null) {
      final text = _msgController.text;
      String cipher;

      // Cryptographic Routing Logic:
      if (_selectedPeer!.rawPublicKey.isNotEmpty) {
        // If we have their true public key, use it to encrypt!
        final targetPubKey = RSAPublicKey.fromString(_selectedPeer!.rawPublicKey);
        cipher = targetPubKey.encrypt(text);
      } else {
        // Fallback for the very first connection initialization message
        cipher = _privKey.publicKey.encrypt(text);
      }

      _channel.sink.add(jsonEncode({
        "type": "message",
        "fromUser": _myFingerprint,
        "toUser": _selectedPeer!.fingerprint,
        "payload": jsonEncode({"pubKey": _myFullPublicKeyString, "cipher": cipher})
      }));

      setState(() => _selectedPeer!.messages.add("Me: $text"));
      _msgController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_myFingerprint.isEmpty) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 260, color: const Color(0xFF1A1A1A),
            child: SafeArea(
              child: Column(children: [
                ListTile(
                  title: const Text('Secure Chats', style: TextStyle(fontWeight: FontWeight.bold)),
                  trailing: IconButton(icon: const Icon(Icons.add_circle_outline, color: Colors.tealAccent), onPressed: _showAddPeer),
                ),
                const Divider(color: Colors.white10, height: 1),
                Expanded(child: ListView(children: _peers.map((p) => ListTile(
                  selected: _selectedPeer == p, selectedTileColor: Colors.white10,
                  leading: CircleAvatar(backgroundColor: Colors.tealAccent.withOpacity(0.1), child: Text(p.nickname.isEmpty ? "?" : p.nickname[0].toUpperCase(), style: const TextStyle(color: Colors.tealAccent))),
                  title: Text(p.nickname), subtitle: Text(p.fingerprint, overflow: TextOverflow.ellipsis),
                  onTap: () => setState(() => _selectedPeer = p),
                )).toList())),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: _myFingerprint));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Node ID copied to clipboard'), duration: Duration(seconds: 2), backgroundColor: Color(0xFF1E1E1E)));
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(children: [
                      Expanded(child: Text('My Node ID: $_myFingerprint', style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.white30), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      const Icon(Icons.copy, size: 12, color: Colors.white30),
                    ]),
                  ),
                )
              ]),
            ),
          ),
          Expanded(
            child: _selectedPeer == null
              ? const Center(child: Text('No Active Pipeline Selection', style: TextStyle(color: Colors.white30)))
              : SafeArea(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ListTile(title: Text(_selectedPeer!.nickname, style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)), subtitle: Text('Target: ${_selectedPeer!.fingerprint}', style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
                    const Divider(height: 1, color: Colors.white10),
                    Expanded(
                      child: StreamBuilder(
                        stream: _channel.stream,
                        builder: (context, snap) {
                          if (snap.hasData) {
                            try {
                              final data = jsonDecode(snap.data.toString());
                              final innerPayload = jsonDecode(data['payload']);
                              final String senderFp = data['fromUser'];
                              final String senderPubKey = innerPayload['pubKey'];
                              final String cipherText = innerPayload['cipher'];
                              
                              String decrypted;
                              try {
                                decrypted = _privKey.decrypt(cipherText);
                              } catch (_) {
                                // First-packet fallback parser
                                final senderPubKeyObject = RSAPublicKey.fromString(senderPubKey);
                                decrypted = senderPubKeyObject.decrypt(cipherText);
                              }

                              // Find or handle peer dynamically
                              bool peerExists = _peers.any((p) => p.fingerprint == senderFp);
                              if (peerExists) {
                                final sender = _peers.firstWhere((p) => p.fingerprint == senderFp);
                                String cleanMsg = "${sender.nickname}: $decrypted";
                                if (!sender.messages.contains(cleanMsg)) {
                                  sender.messages.add(cleanMsg);
                                  // Update their public key mirror reference if it was blank
                                  if (sender.rawPublicKey.isEmpty) {
                                    _peers[_peers.indexOf(sender)] = ChatPeer(senderFp, senderPubKey, sender.nickname)..messages = sender.messages;
                                  }
                                }
                              } else {
                                // Trigger popup dynamically on the UI loop thread context safely
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (!_peers.any((p) => p.fingerprint == senderFp)) {
                                    _showUnknownPeerDialog(senderFp, senderPubKey, decrypted);
                                  }
                                });
                              }
                            } catch (_) {}
                          }

                          return ListView(
                            padding: const EdgeInsets.all(24),
                            children: _selectedPeer!.messages.map((m) => Container(
                              margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12)),
                              child: Text(m),
                            )).toList(),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Row(children: [
                        Expanded(child: TextField(controller: _msgController, decoration: const InputDecoration(hintText: 'Type secure packet...', filled: true, fillColor: Color(0xFF1E1E1E), border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide.none)))),
                        const SizedBox(width: 12),
                        FloatingActionButton(backgroundColor: Colors.tealAccent, onPressed: _sendMessage, child: const Icon(Icons.send, color: Colors.black)),
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