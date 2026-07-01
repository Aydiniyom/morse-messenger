import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';

class NotificationService {
  static final _localNotificationsPlugin = FlutterLocalNotificationsPlugin();
  
  // --- ADDED: Initialization Tracking Flag ---
  static bool _isInitialized = false;

  static Future<void> initialize() async {
    if (kIsWeb || _isInitialized) return;

    try {
      if (Platform.isAndroid) {
        const initializationSettingsAndroid =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        
        const initializationSettings = InitializationSettings(
          android: initializationSettingsAndroid,
        );

        await _localNotificationsPlugin.initialize(
          settings: initializationSettings,
          onDidReceiveNotificationResponse: (details) {
            debugPrint("Android notification clicked: ${details.payload}");
          },
        );
        _isInitialized = true;
      } 
      else if (Platform.isWindows || Platform.isLinux) {
        await localNotifier.setup(
          appName: 'Morse Messenger',
          shortcutPolicy: ShortcutPolicy.requireCreate, 
        );
        _isInitialized = true; // Set to true only after setup completes
      }
    } catch (e) {
      debugPrint("Failed to initialize NotificationService: $e");
    }
  }

  static Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (kIsWeb) return;

    // --- ADDED: Fallback Safety Check ---
    if (!_isInitialized) {
      debugPrint("NotificationService requested before initialization. Initializing now...");
      await initialize();
      if (!_isInitialized) return; // Abort if initialization still failed to avoid crash
    }

    if (Platform.isAndroid) {
      const androidDetails = AndroidNotificationDetails(
        'morse_messages_channel',
        'Incoming Messages',
        channelDescription: 'Alerts for newly arrived private payloads',
        importance: Importance.max,
        priority: Priority.high,
      );

      const notificationDetails = NotificationDetails(android: androidDetails);
      await _localNotificationsPlugin.show(
        id: id, 
        title: title, 
        body: body, 
        notificationDetails: notificationDetails, 
        payload: payload,
      );
    } 
    else if (Platform.isWindows || Platform.isLinux) {
      LocalNotification notification = LocalNotification(
        identifier: id.toString(),
        title: title,
        body: body,
      );

      notification.onClick = () {
        debugPrint("Desktop notification clicked: $id");
      };

      notification.onClose = (closeReason) {
        debugPrint("Desktop notification closed: $id, reason: $closeReason");
      };

      await notification.show();
    }
  }
}