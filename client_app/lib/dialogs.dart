import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class Dialogs {
  static void showUnknownPeerDialog({
    required BuildContext context,
    required String senderPublicKey,
    required String initialMessage,
    required String msgId,
    required arrivalTime,
    required Function(String nickname, String msgId, DateTime time) onAccept,
  }) {
    final TextEditingController incomingNameController =
        TextEditingController();
    final shortSenderId = senderPublicKey.substring(
      senderPublicKey.length - 15,
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Incoming Message Request',
          style: TextStyle(color: Colors.tealAccent),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'From Short-ID: $shortSenderId',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: incomingNameController,
              decoration: const InputDecoration(
                hintText: "Assign a Nickname...",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Decline',
              style: TextStyle(color: Colors.white60),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
            onPressed: () {
              if (incomingNameController.text.isNotEmpty) {
                onAccept(
                  incomingNameController.text.trim(),
                  msgId,
                  arrivalTime,
                );
                Navigator.pop(ctx);
              }
            },
            child: const Text(
              'Converse',
              style: TextStyle(color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }

  static void showIdentityModal({
    required BuildContext context,
    required String shortId,
    required String rawPublicKey,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Row(
          children: [
            const Text('My Identity', style: TextStyle(fontSize: 16)),
            const Spacer(),
            Text(
              'Short-ID: $shortId',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.tealAccent,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        content: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(8),
          ),
          constraints: const BoxConstraints(maxHeight: 180),
          child: SingleChildScrollView(
            child: Text(
              rawPublicKey,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Colors.white30,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
            icon: const Icon(Icons.copy, size: 16, color: Colors.black),
            label: const Text(
              'Copy Identity',
              style: TextStyle(color: Colors.black),
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: rawPublicKey));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Public Key successfully copied to clipboard!'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static void showAddPeer({
    required BuildContext context,
    required TextEditingController nameController,
    required TextEditingController keyInputController,
    required Function(String nickname, String key) onConnect,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Connect to New Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(hintText: "Nickname..."),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: keyInputController,
                    decoration: const InputDecoration(
                      hintText: "Identity key...",
                      // Implicitly uses your global 12px rounded theme
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.tealAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: const BorderSide(color: Colors.white10),
                      backgroundColor: const Color(0xFF1A1A1A),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: () async {
                      final data = await Clipboard.getData(Clipboard.kTextPlain);
                      if (data != null && data.text != null) {
                        keyInputController.text = data.text!;
                      }
                    },
                    label: const Text("Paste"),
                    icon: const Icon(Icons.paste, size: 16),
                  ),
                ),
              ],
            )
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.tealAccent),
            onPressed: () {
              if (keyInputController.text.isNotEmpty &&
                  nameController.text.isNotEmpty) {
                onConnect(
                  nameController.text.trim(),
                  keyInputController.text.trim(),
                );
                Navigator.pop(ctx);
              }
            },
            child: const Text('Connect', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }
}
