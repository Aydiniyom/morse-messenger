import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'storage_service.dart';

class ImagePreviewWidget extends StatelessWidget {
  final String fileName;
  final Uint8List bytes;

  const ImagePreviewWidget({
    super.key,
    required this.fileName,
    required this.bytes,
  });

  Future<void> saveToDevice(BuildContext context) async {
    try {
      final targetDir = await StorageService.getPublicDownloadsDirectory();
      final savePath = '${targetDir.path}/$fileName';
      final file = File(savePath);
      
      await file.writeAsBytes(bytes);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to Downloads: $savePath'),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save media: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
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