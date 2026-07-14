import 'package:client_app/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'chat_screen.dart';
import 'storage_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // StorageService throws when it can't set up encrypted storage, so we need
  // somewhere for that to go.
  String? startupError;
  try {
    await StorageService.initDatabase();
  } catch (e) {
    debugPrint('Fatal: failed to initialize local storage: $e');
    startupError = 'Could not initialize secure local storage. Please restart the app.';
  }

  try {
    await NotificationService.initialize();
  } catch (e) {
    debugPrint('Notification service failed to initialize: $e');
  }

  runApp(MyApp(startupError: startupError));
}

class MyApp extends StatelessWidget {
  final String? startupError;

  const MyApp({super.key, this.startupError});

  @override
  Widget build(BuildContext context) {
    const teal = Colors.tealAccent;
    const darkBackground = Color(0xFF141414);
    const surfaceCard = Color(0xFF1A1A1A);

    return MaterialApp(
      title: 'Morse Messenger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: darkBackground,

        colorScheme: ColorScheme.dark(
          primary: teal,
          onPrimary: Colors.black,
          secondary: teal,
          surface: darkBackground,
        ),

        listTileTheme: ListTileThemeData(
          selectedColor: teal,
          selectedTileColor: const Color(0xFF262626),
          iconColor: Colors.white70,
          textColor: Colors.white,
        ),

        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: surfaceCard,
          hintStyle: TextStyle(color: Colors.white30),
          labelStyle: TextStyle(color: teal),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: teal, width: 1.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Colors.white10),
          ),
        ),

        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: teal,
          selectionColor: Color(0xFF2D4F4F),
          selectionHandleColor: teal,
        ),

        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: teal,
          foregroundColor: Colors.black,
        ),

        dialogTheme: const DialogThemeData(
          backgroundColor: surfaceCard,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: startupError != null
          ? _StartupErrorScreen(message: startupError!)
          : const DecentralizedChat(),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  final String message;
  const _StartupErrorScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
