import 'package:flutter/material.dart';
import 'chat_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
          surfaceTintColor: Colors.transparent, // Prevents Material 3's purple tinting tint
        ),
      ),
      home: const DecentralizedChat(),
    );
  }
}