import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'screens/auth_screen.dart';
import 'screens/map_screen.dart';
import 'services/foreground_service.dart';
import 'services/settings_service.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Charger les paramètres utilisateur (thème, police, carte...)
  await SettingsService.instance.load();

  // Forcer le mode portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // Foreground service — Android uniquement
  // Sur iOS, cette méthode est un no-op (voir foreground_service.dart)
  if (Platform.isAndroid) {
    await ForegroundServiceManager.initialiser();
  }
  runApp(const FayowApp());
}

class FayowApp extends StatelessWidget {
  const FayowApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;

    // Reconstruit le MaterialApp à chaque changement de paramètre
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'FaYoW',
          debugShowCheckedModeBanner: false,
          theme: settings.buildTheme(Brightness.light),
          darkTheme: settings.buildTheme(Brightness.dark),
          themeMode: settings.themeMode,
          // Applique la taille de texte choisie (par-dessus celle du système)
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(
                  mq.textScaler.scale(1) * settings.textScale,
                ),
              ),
              child: child!,
            );
          },
          home: FirebaseAuth.instance.currentUser != null
              ? const MapScreen()
              : const AuthScreen(),
        );
      },
    );
  }
}