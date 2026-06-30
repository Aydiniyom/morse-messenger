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
  final String rawPublicKey;
  final String shortId;
  String nickname;
  List<String> messages = [];
  ChatPeer(this.rawPublicKey, this.nickname) 
    : shortId = rawPublicKey.substring(rawPublicKey.length - 15);
}

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
    
    // 1. Register with backend
    _channel.sink.add(jsonEncode({"type": "register", "fromUser": _myRawPublicKey, "toUser": "", "payload": ""}));

    // 2. GLOBAL LISTEN: Captures background packets even if no chats are open or selected
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
          if (!sender.messages.contains(dec)) sender.messages.add("${sender.nickname}: $dec");
        });
      } else {
        _showUnknownPeerDialog(senderPublicKey, dec);
      }
    } catch (_) {}
  }

  void _showUnknownPeerDialog(String senderPublicKey, String initialMessage) {
    final TextEditingController incomingNameController = TextEditingController();
    final shortSenderId = senderPublicKey.substring(senderPublicKey.length - 15);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Incoming Pipeline Link', style: TextStyle(color: Colors.tealAccent)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('From Node Short-ID: $shortSenderId', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(controller: incomingNameController, decoration: const InputDecoration(hintText: "Assign a Nickname")),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
            onPressed: () {
              if (incomingNameController.text.isNotEmpty) {
                setState(() {
                  final newPeer = ChatPeer(senderPublicKey, incomingNameController.text.trim());
                  newPeer.messages.add("${newPeer.nickname}: $initialMessage");
                  _peers.add(newPeer);
                  _selectedPeer ??= newPeer;
                });
                Navigator.pop(ctx);
              }
            },
            child: const Text('Accept & Open Pipeline', style: TextStyle(color: Colors.black)),
          )
        ],
      ),
    );
  }

  void _showIdentityModal() => showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Row(
        children: [
          const Text('My Cryptographic Identity', style: TextStyle(fontSize: 16)),
          const Spacer(),
          Text('ID: $_myShortId', style: const TextStyle(fontSize: 12, color: Colors.tealAccent, fontFamily: 'monospace')),
        ],
      ),
      content: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
        constraints: const BoxConstraints(maxHeight: 180),
        child: SingleChildScrollView(
          child: Text(_myRawPublicKey, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.white30)),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
          icon: const Icon(Icons.copy, size: 16, color: Colors.black),
          label: const Text('Copy Key Armor', style: TextStyle(color: Colors.black)),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _myRawPublicKey));
            Navigator.pop(ctx);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Public Key successfully compiled to clipboard!')));
          },
        )
      ],
    ),
  );

  void _showAddPeer() => showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text('Connect to Public Key Armor'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _nameController, decoration: const InputDecoration(hintText: "Give them a Nickname")),
        const SizedBox(height: 8),
        TextField(controller: _keyInputController, decoration: const InputDecoration(hintText: "Paste their Giant Public Key String")),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
          onPressed: () {
            if (_keyInputController.text.isNotEmpty && _nameController.text.isNotEmpty) {
              setState(() => _peers.add(ChatPeer(_keyInputController.text.trim(), _nameController.text.trim())));
              _selectedPeer ??= _peers.last;
              _keyInputController.clear(); _nameController.clear();
              Navigator.pop(ctx);
            }
          },
          child: const Text('Secure Link', style: TextStyle(color: Colors.black)),
        )
      ],
    ),
  );

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
      
      setState(() { _selectedPeer!.messages.add("Me: $text"); });
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
                ListTile(
                  title: const Text('Pipelines', style: TextStyle(fontWeight: FontWeight.bold)),
                  trailing: IconButton(icon: const Icon(Icons.add_circle_outline, color: Colors.tealAccent), onPressed: _showAddPeer),
                ),
                const Divider(color: Colors.white10, height: 1),
                Expanded(child: ListView(children: _peers.map((p) => ListTile(
                  selected: _selectedPeer == p, selectedTileColor: Colors.white10,
                  leading: CircleAvatar(backgroundColor: Colors.tealAccent.withOpacity(0.1), child: Text(p.nickname[0].toUpperCase(), style: const TextStyle(color: Colors.tealAccent))),
                  title: Text(p.nickname), subtitle: Text('Node: ${p.shortId}', style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
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
                      onPressed: _showIdentityModal,
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
                    ListTile(title: Text(_selectedPeer!.nickname, style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)), subtitle: Text('Target: ${_selectedPeer!.shortId}', style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
                    const Divider(height: 1, color: Colors.white10),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(24),
                        children: _selectedPeer!.messages.map((m) => Container(
                          margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12)),
                          child: Text(m),
                        )).toList(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Row(children: [
                        Expanded(child: TextField(controller: _msgController, decoration: const InputDecoration(hintText: 'Type secure packet...', filled: true, fillColor: Color(0xFF1E1E1E), border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide.none)))),
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