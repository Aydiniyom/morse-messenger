import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class ImagePreviewWidget extends StatelessWidget {
  final String fileName;
  final Uint8List bytes;

  const ImagePreviewWidget({
    super.key,
    required this.fileName,
    required this.bytes,
  });

  // CHANGED FROM _saveToDevice to saveToDevice to make it accessible from chat_screen.dart
  void saveToDevice(BuildContext context) async {
    try {
      // Direct binary save across Android/iOS/Desktop
      final directory = Directory('/storage/emulated/0/Download');
      String basePath = (await directory.exists())
          ? directory.path
          : Directory.systemTemp.path;

      final savePath = '$basePath/$fileName';
      final file = File(savePath);
      await file.writeAsBytes(bytes);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved directly to Downloads: $fileName'),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save media: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded, color: Colors.white),
            onPressed: () => saveToDevice(context),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          clipBehavior: Clip.none,
          maxScale: 4.0,
          child: Image.memory(bytes),
        ),
      ),
    );
  }
}