import 'dart:async';
import 'dart:io';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _estEnCoursDeLecture = false;
  // Exposer l'instance pour CommuneService
  FlutterTts get tts => _tts;

  /// [ignorerModeSilencieux] (iOS uniquement) :
  /// - true  : catégorie "playback" + duckOthers → les autres sources audio
  ///           sont atténuées pendant la lecture, mais le bouton silencieux
  ///           de l'iPhone est ignoré (limitation d'iOS : duckOthers n'existe
  ///           pas avec la catégorie "ambient" qui respecte ce bouton).
  /// - false : catégorie "ambient" → le bouton silencieux est respecté,
  ///           mais les autres sources audio ne sont pas atténuées.
  /// Prévu pour être branché plus tard sur un écran de paramétrage.
  Future<void> initialiser({bool ignorerModeSilencieux = true}) async {
    await _tts.setLanguage('fr-FR');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    if (Platform.isIOS) {
      if (ignorerModeSilencieux) {
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.duckOthers,
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
      } else {
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.ambient,
          [IosTextToSpeechAudioCategoryOptions.mixWithOthers],
        );
      }
    } else if (Platform.isAndroid) {
      // Usage "guidage vocal" : les autres applis audio baissent leur volume
      // plutôt que de se mettre en pause.
      await _tts.setAudioAttributesForNavigation();
    }
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
    // focus: true → demande le focus audio Android (atténuation des autres
    // sources) ; sans effet sur iOS, géré par la catégorie audio ci-dessus.
    await _tts.speak(texte, focus: true);
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