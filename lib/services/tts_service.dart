import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _estEnCoursDeLecture = false;
  // Exposer l'instance pour CommuneService
  FlutterTts get tts => _tts;
  Future<void> initialiser() async {
    await _tts.setLanguage('fr-FR');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

Future<void> lire(String texte) async {
  print('=== TTS lire() appelé, estEnCours=$_estEnCoursDeLecture ===');
  if (_estEnCoursDeLecture) {
    print('=== TTS déjà en cours, on ignore ===');
    return;
  }
  _estEnCoursDeLecture = true;

  final completer = Completer<void>();

  _tts.setCompletionHandler(() {
    print('=== TTS CompletionHandler déclenché ===');
    _estEnCoursDeLecture = false;
    if (!completer.isCompleted) completer.complete();
  });

  _tts.setCancelHandler(() {
    print('=== TTS CancelHandler déclenché ===');
    _estEnCoursDeLecture = false;
    if (!completer.isCompleted) completer.complete();
  });

  _tts.setErrorHandler((message) {
    print('=== TTS ErrorHandler déclenché : $message ===');
    _estEnCoursDeLecture = false;
    if (!completer.isCompleted) completer.complete();
  });

  print('=== TTS speak() lancé ===');
  await _tts.speak(texte);
  print('=== TTS speak() retourné, attente completer ===');
  await completer.future;
  print('=== TTS completer résolu, lecture terminée ===');
}

  Future<void> arreter() async {
    await _tts.stop();
    _estEnCoursDeLecture = false;
  }

  bool get estEnCoursDeLecture => _estEnCoursDeLecture;

  void dispose() {
    _tts.stop();
  }
}