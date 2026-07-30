import 'package:client_app/main.dart';
import 'package:client_app/models.dart';
import 'package:client_app/rounded_divider.dart';
import 'package:client_app/storage_service.dart';
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
                    setInnerState(() {});

                    Future.delayed(const Duration(milliseconds: 150), () async {
                      useSystemColorNotifier.value = value;

                      await StorageService.saveColorsToggle(true);
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
                  overlayColor: Colors.transparent,
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
                          style: TextButton.styleFrom(overlayColor: Colors.transparent),
                          onPressed: () => Navigator.pop(confirmCtx),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            overlayColor: Colors.transparent,
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
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(overlayColor: Colors.transparent),
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
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Developer:'),
                SizedBox(
                  height: 30,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      overlayColor: Colors.transparent,
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
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('App Repo:'),
                SizedBox(
                  height: 30,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      overlayColor: Colors.transparent,
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
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
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
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Decline',
              style: TextStyle(color: Colors.white60),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              overlayColor: Colors.transparent,
              backgroundColor: theme.colorScheme.primary,
            ),
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
            Flexible(
              child: Text(
                'Short-ID: $shortId',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.primary,
                  fontFamily: 'monospace',
                ),
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
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              overlayColor: Colors.transparent,
              backgroundColor: theme.colorScheme.primary,
            ),
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

  /// A small, fixed set of quick-reaction emojis - shown from the message
  /// context menu's "React" option. [onSelected] fires once with the
  /// chosen emoji; toggling add/remove is the caller's responsibility
  /// (tapping an emoji you've already reacted with un-reacts).
  static void showReactionPicker({
    required BuildContext context,
    required Function(String emoji) onSelected,
  }) {
    const emojis = [
      '👍',
      '👎',
      '❤️',
      '😍',
      '😭',
      '😂',
      '😢',
      '🙏',
      '🐳',
      '🤷',
      '😁',
    ];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('React', style: TextStyle(fontSize: 16)),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: emojis.map((emoji) {
            return GestureDetector(
              onTap: () {
                Navigator.pop(ctx);
                onSelected(emoji);
              },
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 26)),
              ),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
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
                      overlayColor: Colors.transparent,
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
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              overlayColor: Colors.transparent,
              backgroundColor: theme.colorScheme.primary,
            ),
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

  /// Entry point behind the "+" button. Instead of jumping straight into
  /// "Add Contact", this lets the user choose what kind of new
  /// conversation they want to start; each option hands off to its own
  /// dialog below.
  static void showAddOptions({
    required BuildContext context,
    required VoidCallback onCreateGroup,
    required VoidCallback onJoinGroup,
    required VoidCallback onAddContact,
  }) {
    final ThemeData theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Add'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.group_add_rounded, color: theme.colorScheme.primary),
              title: const Text('Create Group'),
              onTap: () {
                Navigator.pop(ctx);
                onCreateGroup();
              },
            ),
            ListTile(
              leading: Icon(Icons.login_rounded, color: theme.colorScheme.primary),
              title: const Text('Join Group'),
              onTap: () {
                Navigator.pop(ctx);
                onJoinGroup();
              },
            ),
            ListTile(
              leading: Icon(Icons.person_add_alt_1_rounded, color: theme.colorScheme.primary),
              title: const Text('Add Contact'),
              onTap: () {
                Navigator.pop(ctx);
                onAddContact();
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  /// Creates a brand-new group. You name it locally - exactly like naming
  /// a contact in [showAddPeer] - and pick which of your existing contacts
  /// to seed the allow-list with (you can always add more, or add people
  /// who aren't contacts yet, later from group settings). The relay is
  /// never told the group exists; after creation, [showGroupInvite] shows
  /// a code to share with those members out-of-band so they can join via
  /// [showJoinGroup].
  static void showCreateGroup({
    required BuildContext context,
    required List<ChatPeer> contacts,
    required Function(String groupName, List<String> memberKeys) onCreate,
  }) {
    final ThemeData theme = Theme.of(context);
    final nameController = TextEditingController();
    final Set<String> selectedKeys = {};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInnerState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text('Create Group'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(hintText: "Group name..."),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Add contacts (optional - you can add more later '
                    'from group settings):',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  if (contacts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        'No contacts yet - add some first, or create the '
                        'group empty and add people later.',
                        style: TextStyle(color: Colors.white30, fontSize: 12),
                      ),
                    )
                  else
                    Container(
                      constraints: const BoxConstraints(maxHeight: 220),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: contacts.length,
                        itemBuilder: (ctx, i) {
                          final contact = contacts[i];
                          final isSelected = selectedKeys.contains(
                            contact.rawPublicKey,
                          );
                          return CheckboxListTile(
                            dense: true,
                            value: isSelected,
                            activeColor: theme.colorScheme.primary,
                            title: Text(
                              contact.nickname,
                              style: const TextStyle(fontSize: 13),
                            ),
                            onChanged: (checked) {
                              setInnerState(() {
                                if (checked == true) {
                                  selectedKeys.add(contact.rawPublicKey);
                                } else {
                                  selectedKeys.remove(contact.rawPublicKey);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(overlayColor: Colors.transparent),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  overlayColor: Colors.transparent,
                  backgroundColor: theme.colorScheme.primary,
                ),
                onPressed: () {
                  if (nameController.text.trim().isEmpty) return;
                  // Dismiss this dialog *before* onCreate runs - it opens
                  // the invite-code dialog right away, and popping
                  // afterwards would close that new dialog instead of this
                  // one (since Navigator.pop just closes whatever's on
                  // top).
                  Navigator.pop(ctx);
                  onCreate(nameController.text.trim(), selectedKeys.toList());
                },
                child: const Text('Create', style: TextStyle(color: Colors.black)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Shown right after a group is created: the invite code to copy and
  /// send to your members out-of-band (however you'd normally reach
  /// them) - pasting it into [showJoinGroup] is how they get in.
  static void showGroupInvite({
    required BuildContext context,
    required String inviteCode,
  }) {
    final ThemeData theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Group Created'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Share this invite code with your members. They\'ll paste it '
              'into "Join Group".',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(8),
              ),
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                child: Text(
                  inviteCode,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: Colors.white30,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              overlayColor: Colors.transparent,
              backgroundColor: theme.colorScheme.primary,
            ),
            icon: const Icon(Icons.copy, size: 16, color: Colors.black),
            label: const Text(
              'Copy Invite Code',
              style: TextStyle(color: Colors.black),
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: inviteCode));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Invite code copied to clipboard!'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Shown on long-pressing a contact - lets you copy their public key so
  /// you can paste it elsewhere (e.g. into a group's allow-list).
  static void showPeerKeyDialog({
    required BuildContext context,
    required String nickname,
    required String rawPublicKey,
  }) {
    final ThemeData theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(nickname, style: const TextStyle(fontSize: 16)),
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
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              overlayColor: Colors.transparent,
              backgroundColor: theme.colorScheme.primary,
            ),
            icon: const Icon(Icons.copy, size: 16, color: Colors.black),
            label: const Text(
              'Copy Public Key',
              style: TextStyle(color: Colors.black),
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: rawPublicKey));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Copied $nickname\'s public key!')),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Opened via "Modify" from a group's sidebar context menu (long-press
  /// the group). Shows the group's invite code - always the same value,
  /// always copyable, and no longer tied to who's currently a member - and
  /// lets any current member
  /// extend or shrink the allow-list. The introducer is the sole source of
  /// truth for this list (see chat_screen.dart's allow-list handlers), so
  /// the count shown here is always what the introducer has, not a local
  /// guess that can drift between devices. Removing a key that belongs to
  /// a current member kicks them from the group.
  static void showGroupSettings({
    required BuildContext context,
    required String groupName,
    required String inviteCode,
    required List<String> allowedJoinerKeys,
    required String Function(String rawKey) labelForKey,
    required Function(List<String> newKeys) onAddAllowedKeys,
    required Function(String key) onRemoveAllowedKey,
  }) {
    final ThemeData theme = Theme.of(context);
    final newKeysController = TextEditingController();
    final localKeys = List<String>.from(allowedJoinerKeys);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInnerState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: Text('$groupName Settings'),
            // AlertDialog sizes its content intrinsically unless told
            // otherwise, and the allow-list ListView.builder below can't
            // report an intrinsic width (Viewport doesn't support that) -
            // without this explicit width, that measurement throws and
            // the dialog never actually renders (you just see the
            // darkened barrier). Same fix already used in
            // showReadByDialog below.
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Invite code - anyone can use this to request to '
                      'join, but they still need their key added below '
                      'before they\'ll be let in.',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      constraints: const BoxConstraints(maxHeight: 120),
                      child: SingleChildScrollView(
                        child: Text(
                          inviteCode,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: Colors.white30,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          overlayColor: Colors.transparent,
                          foregroundColor: theme.colorScheme.primary,
                          side: const BorderSide(color: Colors.white10),
                        ),
                        icon: const Icon(Icons.copy, size: 14),
                        label: const Text('Copy Invite Code'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: inviteCode));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Invite code copied to clipboard!'),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    const RoundedDivider(),
                    const SizedBox(height: 16),
                    Text(
                      'Allowed to join (${localKeys.length})',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (localKeys.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Text(
                          'Nobody yet - add a key below.',
                          style: TextStyle(color: Colors.white30, fontSize: 12),
                        ),
                      )
                    else
                      Container(
                        constraints: const BoxConstraints(maxHeight: 160),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: localKeys.length,
                          itemBuilder: (ctx, i) {
                            final key = localKeys[i];
                            return ListTile(
                              dense: true,
                              title: Text(
                                labelForKey(key),
                                style: const TextStyle(fontSize: 13),
                              ),
                              trailing: IconButton(
                                style: IconButton.styleFrom(overlayColor: Colors.transparent),
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  size: 18,
                                  color: Colors.redAccent,
                                ),
                                tooltip: 'Remove (kicks them if they joined)',
                                onPressed: () {
                                  onRemoveAllowedKey(key);
                                  setInnerState(() {
                                    localKeys.removeAt(i);
                                  });
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: newKeysController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: "New members' identity keys, one per line...",
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          overlayColor: Colors.transparent,
                          backgroundColor: theme.colorScheme.primary,
                        ),
                        onPressed: () {
                          final newKeys = newKeysController.text
                              .split('\n')
                              .map((k) => k.trim())
                              .where((k) => k.isNotEmpty)
                              .toList();
                          if (newKeys.isEmpty) return;
                          onAddAllowedKeys(newKeys);
                          newKeysController.clear();
                          setInnerState(() {
                            localKeys.addAll(
                              newKeys.where((k) => !localKeys.contains(k)),
                            );
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Allow-list updated.'),
                            ),
                          );
                        },
                        child: const Text(
                          'Add to Allow-List',
                          style: TextStyle(color: Colors.black),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(overlayColor: Colors.transparent),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Opened by long-pressing a contact or group in either sidebar. The
  /// options shown depend on what kind of entry this is: a DM gets "Info"
  /// (view/copy the contact's public key) and "Mute"; a group gets
  /// "Modify" (the invite code / allow-list editor, formerly reached by
  /// holding the chat header itself - consolidated here for consistency)
  /// and "Mute". [onInfo] and [onModify] are mutually exclusive in
  /// practice (only one is ever non-null depending on [isGroup]) and their
  /// corresponding row is simply omitted when null - e.g. a pending group
  /// you can't modify yet.
  static void showPeerContextMenu({
    required BuildContext context,
    required String title,
    required bool isGroup,
    required bool isMuted,
    VoidCallback? onInfo,
    VoidCallback? onModify,
    required VoidCallback onToggleMute,
  }) {
    final ThemeData theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isGroup && onInfo != null)
              ListTile(
                leading: Icon(Icons.info_outline_rounded, color: theme.colorScheme.primary),
                title: const Text('Info'),
                onTap: () {
                  Navigator.pop(ctx);
                  onInfo();
                },
              ),
            if (isGroup && onModify != null)
              ListTile(
                leading: Icon(Icons.edit_outlined, color: theme.colorScheme.primary),
                title: const Text('Modify'),
                onTap: () {
                  Navigator.pop(ctx);
                  onModify();
                },
              ),
            ListTile(
              leading: Icon(
                isMuted
                    ? Icons.notifications_off_rounded
                    : Icons.notifications_none_rounded,
                color: theme.colorScheme.primary,
              ),
              title: Text(isMuted ? 'Unmute' : 'Mute'),
              onTap: () {
                Navigator.pop(ctx);
                onToggleMute();
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  /// Lists who's read a group message you sent, opened from the message's
  /// "Read By" context menu entry.
  static void showReadByDialog({
    required BuildContext context,
    required List<String> readerLabels,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Read By'),
        content: SizedBox(
          width: double.maxFinite,
          child: readerLabels.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(
                    'No one has read this message yet.',
                    style: TextStyle(color: Colors.white60),
                  ),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: readerLabels.length,
                    itemBuilder: (ctx, i) => ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.check_circle,
                        size: 16,
                        color: Colors.white70,
                      ),
                      title: Text(readerLabels[i]),
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Joins a group from an invite code produced by [showGroupInvite]. You
  /// still pick your own local name for the group here, exactly like
  /// naming a new contact in [showAddPeer].
  static void showJoinGroup({
    required BuildContext context,
    required Function(String groupName, String inviteCode) onJoin,
  }) {
    final ThemeData theme = Theme.of(context);
    final nameController = TextEditingController();
    final inviteController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Join Group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(hintText: "Name for this group..."),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: inviteController,
              maxLines: 4,
              decoration: const InputDecoration(hintText: "Paste invite code..."),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(overlayColor: Colors.transparent),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              overlayColor: Colors.transparent,
              backgroundColor: theme.colorScheme.primary,
            ),
            onPressed: () {
              if (nameController.text.isNotEmpty &&
                  inviteController.text.isNotEmpty) {
                onJoin(nameController.text.trim(), inviteController.text.trim());
                Navigator.pop(ctx);
              }
            },
            child: const Text('Join', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }
}