import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';

class NotificationService {
  static final _localNotificationsPlugin = FlutterLocalNotificationsPlugin();

  static bool _isInitialized = false;

  /// Guards against concurrent calls to [initialize] racing each other.
  /// [main.dart] awaits it once at startup, but [showNotification] also has
  /// a defensive "initialize if needed" fallback; without this guard, a
  /// message arriving mid-startup could trigger a second, overlapping
  /// initialization of the plugin.
  static Completer<void>? _initInFlight;

  static Future<void> initialize() async {
    if (kIsWeb || _isInitialized) return;

    if (_initInFlight != null) {
      return _initInFlight!.future;
    }

    final completer = Completer<void>();
    _initInFlight = completer;

    try {
      if (Platform.isAndroid) {
        const initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
        const initializationSettings = InitializationSettings(android: initializationSettingsAndroid);

        await _localNotificationsPlugin.initialize(
          settings: initializationSettings,
          onDidReceiveNotificationResponse: (details) {
            debugPrint('Android notification clicked: ${details.payload}');
          },
        );
        _isInitialized = true;
      } else if (Platform.isWindows || Platform.isLinux) {
        await localNotifier.setup(
          appName: 'Morse Messenger',
          shortcutPolicy: ShortcutPolicy.requireCreate,
        );
        _isInitialized = true;
      } else {
        _isInitialized = true;
      }
    } catch (e) {
      debugPrint('Failed to initialize NotificationService: $e');
      // Leave _isInitialized false so a later call can retry.
    } finally {
      completer.complete();
      _initInFlight = null;
    }
  }

  static Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (kIsWeb) return;

    if (!_isInitialized) {
      debugPrint('NotificationService requested before initialization. Initializing now...');
      await initialize();
      if (!_isInitialized) return;
    }

    try {
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
      } else if (Platform.isWindows || Platform.isLinux) {
        final notification = LocalNotification(
          identifier: id.toString(),
          title: title,
          body: body,
        );

        notification.onClick = () {
          debugPrint('Desktop notification clicked: $id');
        };

        notification.onClose = (closeReason) {
          debugPrint('Desktop notification closed: $id, reason: $closeReason');
        };

        await notification.show();
      }
    } catch (e) {
      debugPrint('Failed to show notification: $e');
    }
  }
}
