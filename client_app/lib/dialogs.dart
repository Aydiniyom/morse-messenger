import 'package:client_app/main.dart';
import 'package:client_app/rounded_divider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class Dialogs {
  static void showSettingsDialog({
    required BuildContext context,
    required TextEditingController ipController,
    required VoidCallback onResetIdentity,
    required Function(String targetIp) onSaveAndConnect,
  }) {
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
            // NETWORK TARGET
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                hintText: "e.g. 192.168.1.50:8080",
                labelText: "Server Address",
              ),
            ),

            const SizedBox(height: 16),
            const RoundedDivider(),
            const SizedBox(height: 16),

            // SYSTEM COLOR TOGGLE
            StatefulBuilder(
              builder: (context, setInnerState) {
                return SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use System Colors'),
                  activeThumbColor: Theme.of(context).colorScheme.primary,
                  value: useSystemColorNotifier.value,
                  onChanged: (bool value) {
                    setInnerState(() {
                      useSystemColorNotifier.value = value;
                    });
                  },
                );
              },
            ),

            const SizedBox(height: 16),
            const RoundedDivider(),
            const SizedBox(height: 16),

            // DANGER ZONE
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
                  // Dismiss settings window before drawing alert box
                  Navigator.pop(ctx);

                  showDialog(
                    context: context,
                    builder: (confirmCtx) => AlertDialog(
                      title: const Text('Are you absolutely sure?'),
                      content: const Text(
                        'This action destroys your identity permanently. '
                        'Your keys will change, and all of your chats will be deleted.',
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
                            onResetIdentity(); // Trigger parental screen wipe routine
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
              if (ipController.text.isNotEmpty) {
                Navigator.pop(ctx);
                onSaveAndConnect(ipController.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  static void showAboutDialog({required BuildContext context}) {
    final ThemeData theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'About',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Version: dev"),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Developer:'),
                const SizedBox(width: 8),
                SizedBox(
                  height: 30,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: const BorderSide(color: Colors.white10),
                      backgroundColor: const Color(0xFF1A1A1A),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: "https://github.com/aydiniyom"),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Copied GitHub link!')),
                      );
                    },
                    label: const Text('@aydiniyom'),
                    icon: const Icon(Icons.link, size: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('App Repo:'),
                const SizedBox(width: 8),
                SizedBox(
                  height: 30,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: const BorderSide(color: Colors.white10),
                      backgroundColor: const Color(0xFF1A1A1A),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(
                          text: "https://github.com/aydiniyom/morse-messenger",
                        ),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Copied GitHub link!')),
                      );
                    },
                    label: const Text('morse-messenger'),
                    icon: const Icon(Icons.link, size: 16),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Okay'),
          ),
        ],
      ),
    );
  }

  static void showUnknownPeerDialog({
    required BuildContext context,
    required String senderPublicKey,
    required Function(String nickname) onAccept,
  }) {
    final ThemeData theme = Theme.of(context);
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
        title: Text(
          'Incoming Message Request',
          style: TextStyle(color: theme.colorScheme.primary),
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
            style: ElevatedButton.styleFrom(backgroundColor: theme.colorScheme.primary),
            onPressed: () {
              if (incomingNameController.text.isNotEmpty) {
                onAccept(incomingNameController.text.trim());
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
    final ThemeData theme = Theme.of(context);
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
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.primary,
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
            style: ElevatedButton.styleFrom(backgroundColor: theme.colorScheme.primary),
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
    final ThemeData theme = Theme.of(context);
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
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 48,
                  child: IconButton.outlined(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      side: const BorderSide(color: Colors.white10),
                      backgroundColor: const Color(0xFF1A1A1A),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: () async {
                      final data = await Clipboard.getData(
                        Clipboard.kTextPlain,
                      );
                      if (data != null && data.text != null) {
                        keyInputController.text = data.text!;
                      }
                    },
                    icon: const Icon(Icons.paste, size: 16),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: theme.colorScheme.primary),
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
