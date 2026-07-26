import 'package:flutter/material.dart';
import 'models.dart';

/// The small "who do you mean?" popup shown above the compose bar while
/// typing an `@mention` in a group chat - lists whichever group members
/// match what's been typed so far after the `@`, and hands the tapped one
/// back via [onSelected]. Deliberately kept as a small anchored card
/// rather than a full-screen dialog, so it stays out of the way of
/// whatever's already being typed, the same way the reply preview strip
/// sits above the input field without covering it.
class MentionPopup extends StatelessWidget {
  final List<ChatPeer> candidates;
  final String Function(String rawPublicKey) displayNameFor;
  final void Function(ChatPeer candidate) onSelected;

  const MentionPopup({
    super.key,
    required this.candidates,
    required this.displayNameFor,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // Cap how many rows show at once so a large group can't push the
    // compose bar off-screen - the list is already filtered by whatever
    // the user's typed after "@", so this rarely matters in practice.
    final shown = candidates.take(5).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: shown.length,
        itemBuilder: (context, index) {
          final peer = shown[index];
          final name = displayNameFor(peer.rawPublicKey.trim());
          return ListTile(
            dense: true,
            leading: CircleAvatar(
              radius: 14,
              backgroundColor: Colors.white10,
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            title: Text(name, style: const TextStyle(fontSize: 14)),
            onTap: () => onSelected(peer),
          );
        },
      ),
    );
  }
}
