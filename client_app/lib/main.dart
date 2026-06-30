import 'package:flutter/material.dart';
import 'chat_screen.dart';

void main() => runApp(MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData.dark().copyWith(
    scaffoldBackgroundColor: const Color(0xFF121212), 
    primaryColor: Colors.tealAccent,
  ),
  home: const DecentralizedChat(),
));