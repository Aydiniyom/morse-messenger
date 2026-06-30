import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypton/crypton.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const Chat(),
    );
  }
}

class Chat extends StatefulWidget {
  const Chat({super.key});
  @override
  State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> {
  final TextEditingController _controller = TextEditingController();
  final WebSocketChannel _channel = WebSocketChannel.connect(
    Uri.parse('ws://localhost:8080/ws'),
  );

  late RSAPrivateKey _myPrivateKey;
  late String _myFingerprint;
  bool _isReady = false;

  List<String> _decryptedMessages = [];

  @override
  void initState() {
    super.initState();
    _setupIdentity();
  }

  void _setupIdentity() {
    // create cryptographic keys
    final keyPair = RSAKeypair.fromRandom();
    _myPrivateKey = keyPair.privateKey;
    // compress the public key into a clean string ID format (fingerprint, basically)
    _myFingerprint = keyPair.publicKey.toString().substring(30, 80);

    // tell server who we are
    var registerPacket = {
      "type": "register",
      "fromUser": _myFingerprint,
      "toUser": "",
      "payload": "",
    };
    _channel.sink.add(jsonEncode(registerPacket));

    setState(() {
      _isReady = true;
    });
  }

  void _sendMessage() {
    if (_controller.text.isNotEmpty) {
      String plainText = _controller.text;

      // the test is solely based on myself, since I have no one to test this with :D
      String encryptedPayload = _myPrivateKey.publicKey.encrypt(plainText);

      var messagePacket = {
        "type": "message",
        "fromUser": _myFingerprint,
        "toUser": _myFingerprint,
        "payload": encryptedPayload,
      };

      _channel.sink.add(jsonEncode(messagePacket));
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Morse Messenger',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.tealAccent,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Fingerprint ID:\n$_myFingerprint',
                style: const TextStyle(
                  color: Colors.white30,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
              const Divider(height: 32, color: Colors.white24),

              Expanded(
                child: StreamBuilder(
                  stream: _channel.stream,
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      // we received a JSON packet back from the server
                      var incomingData = jsonDecode(snapshot.data.toString());
                      String cipherText = incomingData['payload'];

                      // try to decrypt it locally
                      try {
                        String decrypted = _myPrivateKey.decrypt(cipherText);
                        // add it to our display list if it's new
                        if (!_decryptedMessages.contains(decrypted)) {
                          _decryptedMessages.add(decrypted);
                        }
                      } catch (e) {
                        // if it wasn't encrypted with our key, it throws an error
                      }
                    }

                    return ListView.builder(
                      itemCount: _decryptedMessages.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E1E),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _decryptedMessages[index],
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),

              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FloatingActionButton(
                    backgroundColor: Colors.tealAccent,
                    onPressed: _sendMessage,
                    child: const Icon(Icons.send, color: Colors.black),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
