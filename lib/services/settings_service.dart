import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fonds de carte proposés.
///
/// Les URLs CARTO suivent le format de ton TileLayer actuel
/// ({s} + paramètre ?key=). À utiliser avec subdomains: ['a','b','c','d'].
/// ⚠️ « voyager » n'est pas encore testé avec ta clé : vérifie qu'il s'affiche.
enum MapStyle {
  clair('Clair', Icons.light_mode_outlined),
  sombre('Sombre', Icons.dark_mode_outlined),
  voyager('Voyager (coloré)', Icons.explore_outlined),
  osm('OpenStreetMap', Icons.public);

  const MapStyle(this.label, this.icon);

  final String label;
  final IconData icon;

  String urlTemplate(String cartoApiKey) {
    switch (this) {
      case MapStyle.clair:
        return 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png?key=$cartoApiKey';
      case MapStyle.sombre:
        return 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png?key=$cartoApiKey';
      case MapStyle.voyager:
        return 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png?key=$cartoApiKey';
      case MapStyle.osm:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
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
  FontChoice(null, 'Par défaut (système)'),
  FontChoice('Lato', 'Lato'),
  FontChoice('Nunito', 'Nunito'),
  FontChoice('Merriweather', 'Merriweather (serif)'),
  FontChoice('Lora', 'Lora (serif)'),
  FontChoice('Atkinson Hyperlegible', 'Atkinson Hyperlegible (lisibilité)'),
];

/// Une couleur d'accent proposée.
class AccentColor {
  const AccentColor(this.label, this.color);

  final String label;
  final Color color;
}

const List<AccentColor> settingsColors = [
  AccentColor('Violet (défaut)', Color(0xFF673AB7)),
  AccentColor('Bleu', Color(0xFF1565C0)),
  AccentColor('Turquoise', Color(0xFF00897B)),
  AccentColor('Vert', Color(0xFF2E7D32)),
  AccentColor('Orange', Color(0xFFEF6C00)),
  AccentColor('Rouge', Color(0xFFC62828)),
  AccentColor('Rose', Color(0xFFAD1457)),
  AccentColor('Prune', Color(0xFF6A1B9A)),
  AccentColor('Ardoise', Color(0xFF455A64)),
];

/// Paramètres utilisateur de FaYoW : état observable + persistance locale.
class SettingsService extends ChangeNotifier {
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  static const _kThemeMode = 'settings.themeMode';
  static const _kColorIndex = 'settings.colorIndex';
  static const _kFontFamily = 'settings.fontFamily';
  static const _kTextScale = 'settings.textScale';
  static const _kMapStyle = 'settings.mapStyle';

  SharedPreferences? _prefs;

  ThemeMode _themeMode = ThemeMode.system;
  int _colorIndex = 0;
  String? _fontFamily;
  double _textScale = 1.0;
  MapStyle _mapStyle = MapStyle.clair;

  ThemeMode get themeMode => _themeMode;
  int get colorIndex => _colorIndex;
  Color get seedColor => settingsColors[_colorIndex].color;
  String? get fontFamily => _fontFamily;
  double get textScale => _textScale;
  MapStyle get mapStyle => _mapStyle;

  /// À appeler une fois dans main(), avant runApp().
  Future<void> load() async {
    final p = _prefs = await SharedPreferences.getInstance();

    final themeIdx = p.getInt(_kThemeMode) ?? 0;
    _themeMode = ThemeMode.values[themeIdx.clamp(0, ThemeMode.values.length - 1)];

    final colorIdx = p.getInt(_kColorIndex) ?? 0;
    _colorIndex = colorIdx.clamp(0, settingsColors.length - 1);

    final font = p.getString(_kFontFamily);
    _fontFamily = settingsFonts.any((f) => f.family == font) ? font : null;

    _textScale = (p.getDouble(_kTextScale) ?? 1.0).clamp(0.85, 1.4);

    final mapIdx = p.getInt(_kMapStyle) ?? 0;
    _mapStyle = MapStyle.values[mapIdx.clamp(0, MapStyle.values.length - 1)];

    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    await _prefs?.setInt(_kThemeMode, mode.index);
  }

  Future<void> setColorIndex(int index) async {
    _colorIndex = index.clamp(0, settingsColors.length - 1);
    notifyListeners();
    await _prefs?.setInt(_kColorIndex, _colorIndex);
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

  Future<void> setMapStyle(MapStyle style) async {
    _mapStyle = style;
    notifyListeners();
    await _prefs?.setInt(_kMapStyle, style.index);
  }

  Future<void> reset() async {
    _themeMode = ThemeMode.system;
    _colorIndex = 0;
    _fontFamily = null;
    _textScale = 1.0;
    _mapStyle = MapStyle.clair;
    notifyListeners();
    final p = _prefs;
    if (p != null) {
      await p.remove(_kThemeMode);
      await p.remove(_kColorIndex);
      await p.remove(_kFontFamily);
      await p.remove(_kTextScale);
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