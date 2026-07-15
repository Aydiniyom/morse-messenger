import 'package:client_app/notification_service.dart';
import 'package:flutter/material.dart';
import 'chat_screen.dart';
import 'storage_service.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:media_kit/media_kit.dart';

final ValueNotifier<bool> useSystemColorNotifier = ValueNotifier<bool>(false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // StorageService throws when it can't set up encrypted storage, so we need
  // somewhere for that to go.
  String? startupError;
  bool savedUseSystemColor = false;
  try {
    await StorageService.initDatabase();

    final savedVal = await StorageService.fetchColorsToggle();
    if (savedVal != null) {
      savedUseSystemColor = savedVal == 'true';
    }
  } catch (e) {
    debugPrint('Fatal: failed to initialize local storage: $e');
    startupError =
        'Could not initialize secure local storage. Please restart the app.';
  }

  useSystemColorNotifier.value = savedUseSystemColor;

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

    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        return ValueListenableBuilder<bool>(
          valueListenable: useSystemColorNotifier,
          builder: (context, useSystemColor, child) {
            Color activeAccent = teal;

            if (useSystemColor) {
              if (darkDynamic != null) {
                activeAccent = darkDynamic.primary;
              } else {
                activeAccent = Theme.of(context).colorScheme.primary;
              }
            }

            return MaterialApp(
              title: 'Morse Messenger',
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                useMaterial3: true,
                brightness: Brightness.dark,
                scaffoldBackgroundColor: darkBackground,

                fontFamily: 'Geomini',
                fontFamilyFallback: ['Vazirmatn'],
                textTheme: ThemeData.dark().textTheme.apply(
                  fontFamily: 'Geomini',
                  fontFamilyFallback: ['Vazirmatn'],
                ),

                colorScheme: ColorScheme.dark(
                  primary: activeAccent,
                  onPrimary: Colors.black,
                  secondary: activeAccent,
                  surface: darkBackground,
                ),

                listTileTheme: ListTileThemeData(
                  selectedColor: activeAccent,
                  selectedTileColor: const Color(0xFF262626),
                  iconColor: Colors.white70,
                  textColor: Colors.white,
                ),

                inputDecorationTheme: InputDecorationTheme(
                  filled: true,
                  fillColor: surfaceCard,
                  hintStyle: const TextStyle(color: Colors.white30),
                  labelStyle: TextStyle(color: activeAccent),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                    borderSide: BorderSide(color: activeAccent, width: 1.5),
                  ),
                  enabledBorder: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    borderSide: BorderSide(color: Colors.white10),
                  ),
                ),

                textSelectionTheme: TextSelectionThemeData(
                  cursorColor: activeAccent,
                  selectionColor: activeAccent.withValues(alpha: 0.3),
                  selectionHandleColor: activeAccent,
                ),

                floatingActionButtonTheme: FloatingActionButtonThemeData(
                  backgroundColor: activeAccent,
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
          },
        );
      },
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
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
