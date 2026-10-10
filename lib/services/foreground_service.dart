import 'dart:io';

// Import conditionnel : flutter_foreground_task ne compile que si Platform.isAndroid
// est vérifié au RUNTIME avant tout appel. L'import en lui-même est ok sur iOS
// car le package est dans pubspec.yaml — seuls les APPELS doivent être guardés.
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

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
        // Le TaskHandler est vide : le GPS tourne dans l'isolate principal.
        // Inutile de réveiller le service toutes les 5 secondes pour ne rien faire.
        eventAction: ForegroundTaskEventAction.nothing(),
        // Le service ne doit démarrer que lorsque l'appli est ouverte et que la
        // permission de localisation est accordée (sinon SecurityException
        // sur Android 14+). Pas de démarrage automatique au boot.
        autoRunOnBoot: false,
        // Verrou CPU conservé par prudence (détection écran éteint). Pour mesurer
        // le gain, essayer à false puis tester 15-20 min écran éteint avec TTS.
        allowWakeLock: true,
        // Verrou Wi-Fi inutile pour ce service : il maintient la radio Wi-Fi
        // en mode haute performance en permanence.
        allowWifiLock: false,
      ),
    );
  }

  static Future<void> demarrer() async {
    if (!Platform.isAndroid) return; // ← no-op iOS

    // Garde-fou indispensable : un service de premier plan de type "location"
    // lève une SecurityException NATIVE (non rattrapable depuis Dart) s'il est
    // démarré sans permission de localisation accordée. On ne le démarre donc
    // que si la permission est bien là.
    if (!await Permission.location.isGranted) return;

    if (await FlutterForegroundTask.isRunningService) return;

    try {
      await FlutterForegroundTask.startService(
        notificationTitle: 'FaYoW actif',
        notificationText: 'Navigation en cours...',
        callback: startCallback,
      );
    } catch (e) {
      // Erreur côté Dart uniquement : l'appli reste utilisable sans le service.
      // ignore: avoid_print
      print('Erreur démarrage foreground service : $e');
    }
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