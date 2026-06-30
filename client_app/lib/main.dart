import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:crypton/crypton.dart'; // Import our new crypto tool

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.tealAccent,
      ),
      home: const CryptoChatScreen(),
    );
  }
}

class CryptoChatScreen extends StatefulWidget {
  const CryptoChatScreen({super.key});

  @override
  State<CryptoChatScreen> createState() => _CryptoChatScreenState();
}

class _CryptoChatScreenState extends State<CryptoChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final WebSocketChannel _channel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080/ws'));

  late RSAPrivateKey _myPrivateKey;
  late RSAPublicKey _myPublicKey;
  
  late RSAPublicKey _targetUserPublicKey; 
  
  bool _isKeyGenerated = false;
  String _lastEncryptedPayload = "";

  @override
  void initState() {
    super.initState();
    _generateKeys();
  }

  void _generateKeys() {
    // Generate a 2048-bit secure keypair
    final keyPair = RSAKeypair.fromRandom();
    _myPrivateKey = keyPair.privateKey;
    _myPublicKey = keyPair.publicKey;
    
    // Pretend our friend's public key is our own for this local loop test
    _targetUserPublicKey = _myPublicKey; 

    setState(() {
      _isKeyGenerated = true;
    });
  }

  void _sendEncryptedMessage() {
    if (_controller.text.isNotEmpty) {
      String plainText = _controller.text;

      // ENCRYPT the text using the target user's Public Key
      // This turns "hello" into unreadable cipher text
      String cipherText = _targetUserPublicKey.encrypt(plainText);

      setState(() {
        _lastEncryptedPayload = cipherText;
      });

      // Send the SCRAMBLED text over the internet to the server
      _channel.sink.add(cipherText);
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isKeyGenerated) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: Colors.tealAccent)));
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Morse Messenger',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.tealAccent),
              ),
              const SizedBox(height: 4),
              Text(
                'Your Fingerprint: ${_myPublicKey.toString().substring(30, 50)}...',
                style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace'),
              ),
              const Divider(height: 32, color: Colors.white24),
              
              const Text("What leaves your device (Encrypted):", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amberAccent)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                width: double.infinity,
                decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  _lastEncryptedPayload.isEmpty ? "No payload sent yet..." : _lastEncryptedPayload,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),

              const SizedBox(height: 24),
              const Text("Server reply (Decrypted client-side):", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
              
              Expanded(
                child: StreamBuilder(
                  stream: _channel.stream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: Text('Send an encrypted packet...'));
                    }

                    // The server echoes back the exact scrambled message string it received
                    String rawServerEcho = snapshot.data.toString();
                    
                    // Since the server doesn't send "Server received: " anymore for raw crypto, 
                    // we directly decrypt the incoming data package using OUR private key.
                    try {
                      String decryptedText = _myPrivateKey.decrypt(rawServerEcho);
                      return Center(
                        child: Text(
                          "Decrypted Cleartext: \"$decryptedText\"",
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      );
                    } catch (e) {
                      return const Center(child: Text("Failed to decrypt incoming payload. Keys mismatch."));
                    }
                  },
                ),
              ),
              
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        hintText: 'Type message...',
                        hintStyle: const TextStyle(color: Colors.white30),
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FloatingActionButton(
                    backgroundColor: Colors.tealAccent,
                    onPressed: _sendEncryptedMessage,
                    child: const Icon(Icons.lock, color: Colors.black),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _channel.sink.close();
    _controller.dispose();
    super.dispose();
  }
}