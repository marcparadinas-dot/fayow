import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fonds de carte proposés (CARTO, même format que ton TileLayer d'origine :
/// sous-domaines {s} + paramètre ?key=). À utiliser avec
/// subdomains: ['a', 'b', 'c', 'd'].
enum MapStyle {
  clair('Clair', Icons.light_mode_outlined),
  sombre('Sombre', Icons.dark_mode_outlined),
  coloree('Colorée', Icons.palette_outlined);

  const MapStyle(this.label, this.icon);

  final String label;
  final IconData icon;

  String urlTemplate(String cartoApiKey) {
    switch (this) {
      case MapStyle.clair:
        return 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png?key=$cartoApiKey';
      case MapStyle.sombre:
        return 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png?key=$cartoApiKey';
      case MapStyle.coloree:
        return 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png?key=$cartoApiKey';
    }
  }
}

/// Une police proposée à l'utilisateur ([family] == null → police système).
class FontChoice {
  const FontChoice(this.family, this.label);

  final String? family;
  final String label;
}

const List<FontChoice> settingsFonts = [
  FontChoice(null, 'Par défaut'),
  FontChoice('Nunito', 'Nunito'),
  FontChoice('Lora', 'Lora (serif)'),
];

/// Une couleur d'accent proposée.
class AccentColor {
  const AccentColor(this.id, this.label, this.color);

  final String id;
  final String label;
  final Color color;
}

const List<AccentColor> settingsColors = [
  AccentColor('violet', 'Violet (défaut)', Color(0xFF673AB7)),
  AccentColor('bleu', 'Bleu', Color(0xFF1565C0)),
  AccentColor('turquoise', 'Turquoise', Color(0xFF00897B)),
  AccentColor('orange', 'Orange', Color(0xFFEF6C00)),
  AccentColor('rose', 'Rose', Color(0xFFAD1457)),
];

/// Paramètres utilisateur de FaYoW : état observable + persistance locale.
class SettingsService extends ChangeNotifier {
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  static const _kDarkMode = 'settings.darkMode';
  static const _kColorId = 'settings.colorId';
  static const _kFontFamily = 'settings.fontFamily';
  static const _kTextScale = 'settings.textScale';
  static const _kVoiceName = 'settings.voiceName';
  static const _kVoiceLocale = 'settings.voiceLocale';
  static const _kMapStyle = 'settings.mapStyle';

  SharedPreferences? _prefs;

  bool _darkMode = false;
  String _colorId = 'violet';
  String? _fontFamily;
  double _textScale = 1.0;
  String? _voiceName;
  String? _voiceLocale;
  MapStyle _mapStyle = MapStyle.clair;

  bool get darkMode => _darkMode;
  ThemeMode get themeMode => _darkMode ? ThemeMode.dark : ThemeMode.light;
  String get colorId => _colorId;
  Color get seedColor =>
      settingsColors.firstWhere((c) => c.id == _colorId).color;
  String? get fontFamily => _fontFamily;
  double get textScale => _textScale;

  /// Voix de lecture choisie (null → voix par défaut du système en fr-FR).
  String? get voiceName => _voiceName;
  String? get voiceLocale => _voiceLocale;
  MapStyle get mapStyle => _mapStyle;

  /// À appeler une fois dans main(), avant runApp().
  Future<void> load() async {
    final p = _prefs = await SharedPreferences.getInstance();

    _darkMode = p.getBool(_kDarkMode) ?? false;

    final colorId = p.getString(_kColorId);
    _colorId = settingsColors.any((c) => c.id == colorId)
        ? colorId!
        : settingsColors.first.id;

    final font = p.getString(_kFontFamily);
    _fontFamily = settingsFonts.any((f) => f.family == font) ? font : null;

    _textScale = (p.getDouble(_kTextScale) ?? 1.0).clamp(0.85, 1.4);

    final voiceName = p.getString(_kVoiceName);
    final voiceLocale = p.getString(_kVoiceLocale);
    if (voiceName != null && voiceLocale != null) {
      _voiceName = voiceName;
      _voiceLocale = voiceLocale;
    }

    final mapIdx = p.getInt(_kMapStyle) ?? 0;
    _mapStyle = MapStyle.values[mapIdx.clamp(0, MapStyle.values.length - 1)];

    notifyListeners();
  }

  Future<void> setDarkMode(bool value) async {
    _darkMode = value;
    notifyListeners();
    await _prefs?.setBool(_kDarkMode, value);
  }

  Future<void> setColor(String id) async {
    if (!settingsColors.any((c) => c.id == id)) return;
    _colorId = id;
    notifyListeners();
    await _prefs?.setString(_kColorId, id);
  }

  Future<void> setFontFamily(String? family) async {
    _fontFamily = family;
    notifyListeners();
    if (family == null) {
      await _prefs?.remove(_kFontFamily);
    } else {
      await _prefs?.setString(_kFontFamily, family);
    }
  }

  Future<void> setTextScale(double scale) async {
    _textScale = scale.clamp(0.85, 1.4);
    notifyListeners();
    await _prefs?.setDouble(_kTextScale, _textScale);
  }

  Future<void> setVoice(String? name, String? locale) async {
    final p = _prefs;
    if (name != null && locale != null) {
      _voiceName = name;
      _voiceLocale = locale;
      notifyListeners();
      await p?.setString(_kVoiceName, name);
      await p?.setString(_kVoiceLocale, locale);
    } else {
      _voiceName = null;
      _voiceLocale = null;
      notifyListeners();
      await p?.remove(_kVoiceName);
      await p?.remove(_kVoiceLocale);
    }
  }

  /// Applique la langue et la voix choisies à une instance FlutterTts.
  /// À appeler juste avant chaque speak() (TtsService, CommuneService).
  Future<void> appliquerVoix(FlutterTts tts) async {
    await tts.setLanguage('fr-FR');
    final name = _voiceName;
    final locale = _voiceLocale;
    if (name != null && locale != null) {
      await tts.setVoice({'name': name, 'locale': locale});
    }
  }

  Future<void> setMapStyle(MapStyle style) async {
    _mapStyle = style;
    notifyListeners();
    await _prefs?.setInt(_kMapStyle, style.index);
  }

  Future<void> reset() async {
    _darkMode = false;
    _colorId = settingsColors.first.id;
    _fontFamily = null;
    _textScale = 1.0;
    _voiceName = null;
    _voiceLocale = null;
    _mapStyle = MapStyle.clair;
    notifyListeners();
    final p = _prefs;
    if (p != null) {
      await p.remove(_kDarkMode);
      await p.remove(_kColorId);
      await p.remove(_kFontFamily);
      await p.remove(_kTextScale);
      await p.remove(_kVoiceName);
      await p.remove(_kVoiceLocale);
      await p.remove(_kMapStyle);
    }
  }

  /// Construit le ThemeData (clair ou sombre) à partir des réglages.
  ThemeData buildTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    // Barre d'appli : la couleur choisie telle quelle en mode clair
    // (comme l'ancien Colors.deepPurple), un peu assombrie en mode sombre.
    final barColor = brightness == Brightness.dark
        ? Color.lerp(seedColor, Colors.black, 0.35)!
        : seedColor;
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        backgroundColor: barColor,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
    );
    final family = _fontFamily;
    if (family == null) return base;
    return base.copyWith(
      textTheme: GoogleFonts.getTextTheme(family, base.textTheme),
    );
  }
}