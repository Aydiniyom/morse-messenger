import 'package:client_app/rounded_divider.dart';
import 'package:client_app/storage_service.dart';
import 'package:flutter/material.dart';
import 'models.dart';

class CompactSidebar extends StatelessWidget {
  final List<ChatPeer> peers;
  final ChatPeer? selectedPeer;
  final Set<String> onlinePeers;
  final VoidCallback onMenuPressed;
  final Function(ChatPeer) onSelectPeer;

  const CompactSidebar({
    super.key,
    required this.peers,
    required this.selectedPeer,
    required this.onlinePeers,
    required this.onMenuPressed,
    required this.onSelectPeer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Matches the color orchestration dictionary used in your expanded sidebar
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;

    return Container(
      width: 68,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        color: cardColor,
      ),
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 73,
              child: Center(
                child: IconButton(
                  icon: Icon(Icons.menu, color: theme.colorScheme.primary),
                  onPressed: onMenuPressed,
                ),
              ),
            ),
            const RoundedDivider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 10.0),
                children: [
                  _buildSavedMessagesTile(context),
                  ...peers
                    .map((p) => _buildMobileAvatarButton(context, p))
                    .toList(),  
                ]
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSavedMessagesTile(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isSelected =
        selectedPeer?.rawPublicKey == StorageService.savedMessagesPeerKey;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: GestureDetector(
        onTap: () => onSelectPeer(
          ChatPeer(rawPublicKey: StorageService.savedMessagesPeerKey, nickname: 'Saved Messages'),
        ),
        child: CircleAvatar(
          radius: 20,
          backgroundColor: isSelected
              ? theme.colorScheme.primary
              : Colors.white10,
          child: Icon(
            Icons.bookmark_border_outlined,
            color: isSelected
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildMobileAvatarButton(BuildContext context, ChatPeer p) {
    final ThemeData theme = Theme.of(context);
    final bool isOnline = onlinePeers.contains(p.rawPublicKey.trim());
    final bool isSelected = selectedPeer == p;

    final baseIndicatorColor = const Color(0xFF1A1A1A);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: GestureDetector(
        onTap: () => onSelectPeer(p),
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: isSelected
                  ? theme.colorScheme.primary
                  : Colors.white10,
              child: Text(
                p.nickname[0].toUpperCase(),
                style: TextStyle(
                  color: isSelected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.primary,
                ),
              ),
            ),
            Positioned(
              right: 14,
              bottom: 2,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: isOnline ? Colors.greenAccent : Colors.blueGrey,
                  shape: BoxShape.circle,
                  border: Border.all(color: baseIndicatorColor, width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
