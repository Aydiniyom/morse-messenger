import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';

class NotificationService {
  static final _localNotificationsPlugin = FlutterLocalNotificationsPlugin();

  static bool _isInitialized = false;

  /// Whether POST_NOTIFICATIONS is currently granted (Android only).
  /// Defaults to true on platforms where the concept doesn't apply, so
  /// callers that gate on this (e.g. BackgroundService) aren't blocked on
  /// desktop/other platforms.
  static bool _notificationsGranted = true;

  static bool get notificationsGranted => _notificationsGranted;

  /// Guards against concurrent calls to [initialize] racing each other.
  /// [main.dart] awaits it once at startup, but [showNotification] also has
  /// a defensive "initialize if needed" fallback; without this guard, a
  /// message arriving mid-startup could trigger a second, overlapping
  /// initialization of the plugin.
  static Completer<bool>? _initInFlight;

  /// Returns whether notification permission is granted. Callers that
  /// depend on notifications actually being postable - most importantly
  /// [BackgroundService], which must post a foreground-service notification
  /// immediately on start or Android kills the app outright - should check
  /// this before proceeding rather than assuming initialize() succeeding
  /// means permission was granted.
  static Future<bool> initialize() async {
    if (kIsWeb) return true;

    if (_isInitialized) return _notificationsGranted;

    if (_initInFlight != null) {
      return _initInFlight!.future;
    }

    final completer = Completer<bool>();
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

        final androidImpl = _localNotificationsPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();

        // Explicitly create the channel BackgroundService's foreground-
        // service notification posts to. flutter_background_service_android
        // will also try to create it on configure(), but that can race with
        // (or be skipped entirely by) its "service already running, reuse
        // existing instance" path on relaunch - so BackgroundService can't
        // rely on the plugin alone to guarantee the channel exists before
        // it calls startForeground().
        const backgroundServiceChannel = AndroidNotificationChannel(
          'morse_background_service',
          'Background Connection',
          description: 'Keeps the relay connection alive in the background',
          importance: Importance.low,
        );
        await androidImpl?.createNotificationChannel(backgroundServiceChannel);

        // Android 13 (API 33) made notifications a runtime permission
        // (POST_NOTIFICATIONS) - it defaults to denied, and unlike most
        // runtime permissions, show() doesn't throw or report failure when
        // it's missing; the notification is just silently dropped. This is
        // the actual reason notifications don't appear on modern Android
        // without the user ever seeing a permission prompt.
        //
        // For a *foreground service* notification specifically, a missing
        // grant is worse than silently dropped: Android throws
        // CannotPostForegroundServiceNotificationException and kills the
        // app when startForeground() can't post. So callers that start a
        // foreground service must check [notificationsGranted] first.
        final granted = await androidImpl?.requestNotificationsPermission();
        _notificationsGranted = granted ?? false;
        if (!_notificationsGranted) {
          debugPrint(
            'Notification permission denied by user - notifications will not be shown, '
            'and any foreground-service start that depends on this will be skipped.',
          );
        }

        _isInitialized = true;
      } else if (Platform.isWindows || Platform.isLinux) {
        await localNotifier.setup(
          appName: 'Morse Messenger',
          shortcutPolicy: ShortcutPolicy.requireCreate,
        );
        _isInitialized = true;
        _notificationsGranted = true;
      } else {
        _isInitialized = true;
        _notificationsGranted = true;
      }
    } catch (e) {
      debugPrint('Failed to initialize NotificationService: $e');
      _notificationsGranted = false;
      // Leave _isInitialized false so a later call can retry.
    } finally {
      completer.complete(_notificationsGranted);
      _initInFlight = null;
    }

    return _notificationsGranted;
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
