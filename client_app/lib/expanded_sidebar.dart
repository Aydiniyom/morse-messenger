import 'package:client_app/rounded_divider.dart';
import 'package:client_app/storage_service.dart';
import 'package:flutter/material.dart';
import 'models.dart';

class ExpandedSidebar extends StatelessWidget {
  final List<ChatPeer> peers;
  final ChatPeer? selectedPeer;
  final Set<String> onlinePeers;
  final VoidCallback onAddPeerPressed;
  final VoidCallback onIdentityPressed;
  final VoidCallback onSettingsPressed;
  final VoidCallback onAboutPressed;
  final Function(ChatPeer) onSelectPeer;

  const ExpandedSidebar({
    super.key,
    required this.peers,
    required this.selectedPeer,
    required this.onlinePeers,
    required this.onAddPeerPressed,
    required this.onIdentityPressed,
    required this.onSettingsPressed,
    required this.onAboutPressed,
    required this.onSelectPeer,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          height: 73,
          child: Center(
            child: ListTile(
              title: const Text(
                'Morse Messenger',
                style: TextStyle(
                  fontWeight: FontWeight.w400,
                  fontFamily: "monospace",
                ),
              ),
              trailing: IconButton(
                icon: Icon(Icons.add, color: theme.colorScheme.primary),
                style: IconButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadiusGeometry.circular(10),
                    side: BorderSide(color: Colors.white10),
                  ),
                ),
                onPressed: onAddPeerPressed,
              ),
            ),
          ),
        ),
        const RoundedDivider(),
        SizedBox(height: 3),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 10.0),
            children: [
              _buildSavedMessagesTile(context),
              ...peers.map((p) => _buildPeerListTile(p, context)),
            ],
          ),
        ),
        const RoundedDivider(),
        _buildSidebarFooterActions(context),
      ],
    );
  }

  Widget _buildSavedMessagesTile(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isSelected =
        selectedPeer?.rawPublicKey == StorageService.savedMessagesPeerKey;

    return ListTile(
      selected: isSelected,
      selectedTileColor: Colors.white10,
      leading: CircleAvatar(
        backgroundColor: isSelected ? theme.colorScheme.primary : Colors.white10,
        child: Icon(
          Icons.bookmark_border_outlined,
          color: isSelected ? Colors.black : theme.colorScheme.primary,
        ),
      ),
      title: Text('Saved Messages'),
      onTap: () {
        onSelectPeer(
          ChatPeer(rawPublicKey: StorageService.savedMessagesPeerKey, nickname: 'Saved Messages'),
        );
      },
    );
  }

  Widget _buildPeerListTile(ChatPeer p, BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isOnline = onlinePeers.contains(p.rawPublicKey.trim());
    final bool isSelected = selectedPeer == p;

    return ListTile(
      selected: isSelected,
      selectedTileColor: Colors.white10,
      leading: Stack(
        children: [
          CircleAvatar(
            backgroundColor: isSelected ? theme.colorScheme.primary : Colors.white10,
            child: p.isPending
            ? Icon(
              Icons.access_time,
              color: isSelected ? Colors.black : theme.colorScheme.primary,
            )
            : Text(
              p.nickname[0].toUpperCase(),
              style: TextStyle(
                color: isSelected ? Colors.black : theme.colorScheme.primary,
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: isOnline ? theme.colorScheme.primary : Color.fromARGB(255, 66, 66, 66),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF1A1A1A), width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Text(p.isPending
          ? '${p.nickname} (pending)'
          : p.nickname,
        style: TextStyle(
          fontStyle: p.isPending ? FontStyle.italic : FontStyle.normal,
        ),
      ),
      onTap: () => onSelectPeer(p),
    );
  }

  Widget _buildSidebarFooterActions(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.primary,
                side: const BorderSide(color: Colors.white10),
              ),
              icon: const Icon(Icons.vpn_key, size: 14),
              label: const Text('Identity', style: TextStyle(fontSize: 14)),
              onPressed: onIdentityPressed,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70, size: 18),
            onPressed: onSettingsPressed,
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(
              Icons.info_rounded,
              color: Colors.white70,
              size: 18,
            ),
            onPressed: onAboutPressed,
          ),
        ],
      ),
    );
  }
}
