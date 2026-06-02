import 'dart:io';

// Import conditionnel : flutter_foreground_task ne compile que si Platform.isAndroid
// est vérifié au RUNTIME avant tout appel. L'import en lui-même est ok sur iOS
// car le package est dans pubspec.yaml — seuls les APPELS doivent être guardés.
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class ForegroundServiceManager {

  static Future<void> initialiser() async {
    if (!Platform.isAndroid) return; // ← no-op iOS, rien d'autre n'est exécuté

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'fayow_foreground',
        channelName: 'FaYoW Service',
        channelDescription: 'Maintient FaYoW actif en arrière-plan',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> demarrer() async {
    if (!Platform.isAndroid) return; // ← no-op iOS

    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      notificationTitle: 'FaYoW actif',
      notificationText: 'Navigation en cours...',
      callback: startCallback,
    );
  }

  static Future<void> arreter() async {
    if (!Platform.isAndroid) return; // ← no-op iOS

    await FlutterForegroundTask.stopService();
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(FayowTaskHandler());
}

class FayowTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}