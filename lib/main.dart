import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'firebase_options.dart';
import 'screens/auth_screen.dart';
import 'screens/map_screen.dart';
import 'services/foreground_service.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  
  // Forcer le mode portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  
  ForegroundServiceManager.initialiser();
  runApp(const FayowApp());
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