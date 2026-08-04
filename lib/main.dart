import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'screens/auth_screen.dart';
import 'screens/map_screen.dart';
import 'services/foreground_service.dart';
import 'package:flutter/services.dart';

void main() {
  // runZonedGuarded attrape toute erreur qui pourrait autrement
  // passer inaperçue (comportement identique pour Android : aucune
  // erreur n'est modifiée ni bloquée, juste enregistrée).
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // --- DIAGNOSTIC iOS UNIQUEMENT ---
    // Affiche un écran de statut pendant le démarrage.
    // N'a aucun effet sur Android (Platform.isIOS = false).
    if (Platform.isIOS) {
      runApp(const DiagnosticApp(status: "Démarrage..."));
    }

    try {
      if (Platform.isIOS) {
        runApp(const DiagnosticApp(status: "Initialisation Firebase..."));
      }

      // Comportement identique à avant pour Android : on attend
      // Firebase.initializeApp(). Seule différence : une limite de
      // 15 secondes est ajoutée pour éviter un blocage infini.
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw Exception(
              "Firebase.initializeApp() a dépassé 15 secondes (timeout)");
        },
      );

      if (Platform.isIOS) {
        runApp(const DiagnosticApp(status: "Firebase OK. Configuration écran..."));
      }

      // Forcer le mode portrait (identique à avant)
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);

      // Foreground service — Android uniquement (identique à avant)
      if (Platform.isAndroid) {
        await ForegroundServiceManager.initialiser();
      }

      runApp(const FayowApp());
    } catch (e, stack) {
      if (Platform.isIOS) {
        // Sur iOS : on affiche l'erreur à l'écran au lieu d'un blanc silencieux.
        runApp(DiagnosticApp(status: "ERREUR AU DEMARRAGE :\n\n$e", isError: true));
      } else {
        // Sur Android : comportement identique à avant, l'erreur remonte normalement.
        rethrow;
      }
    }
  }, (error, stack) {
    // Filet de sécurité pour toute erreur totalement inattendue.
    // ignore: avoid_print
    print("Erreur non interceptee (zone globale): $error");
  });
}

/// Ecran affiché UNIQUEMENT sur iOS pendant le diagnostic.
/// Ne remplace jamais rien sur Android.
class DiagnosticApp extends StatelessWidget {
  final String status;
  final bool isError;

  const DiagnosticApp({super.key, required this.status, this.isError = false});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: isError ? const Color(0xFFFFEBEE) : Colors.white,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Text(
                status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: isError ? const Color(0xFFB71C1C) : Colors.black87,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FayowApp extends StatelessWidget {
  const FayowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FaYoW',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: FirebaseAuth.instance.currentUser != null
          ? const MapScreen()
          : const AuthScreen(),
    );
  }
}