import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/settings_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              const _SectionTitle('Apparence'),

              // --- Clair / sombre ---
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode),
                      label: Text('Clair'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode),
                      label: Text('Sombre'),
                    ),
                  ],
                  selected: {s.themeMode},
                  onSelectionChanged: (v) =>
                      s.setDarkMode(v.first == ThemeMode.dark),
                ),
              ),

              // --- Couleur principale ---
              const _SubTitle('Couleur principale'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final accent in settingsColors)
                      _ColorDot(
                        accent: accent,
                        selected: s.colorId == accent.id,
                        onTap: () => s.setColor(accent.id),
                      ),
                  ],
                ),
              ),

              // --- Police ---
              const _SubTitle('Police'),
              for (final font in settingsFonts)
                ListTile(
                  title: Text(
                    font.label,
                    style: font.family == null
                        ? null
                        : GoogleFonts.getFont(font.family!),
                  ),
                  trailing: s.fontFamily == font.family
                      ? Icon(Icons.check,
                          color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () => s.setFontFamily(font.family),
                ),

              // --- Taille du texte ---
              const _SubTitle('Taille du texte'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text('A', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: s.textScale,
                        min: 0.85,
                        max: 1.4,
                        divisions: 11,
                        label: '${(s.textScale * 100).round()} %',
                        onChanged: s.setTextScale,
                      ),
                    ),
                    const Text('A', style: TextStyle(fontSize: 22)),
                  ],
                ),
              ),

              const Divider(height: 32),
              const _SectionTitle('Carte'),

              // --- Fond de carte ---
              for (final style in MapStyle.values)
                ListTile(
                  leading: Icon(style.icon),
                  title: Text(style.label),
                  trailing: s.mapStyle == style
                      ? Icon(Icons.check,
                          color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () => s.setMapStyle(style),
                ),

              const Divider(height: 32),
              const _SectionTitle('Voix de lecture'),
              const _VoiceSection(),

              const Divider(height: 32),

              // --- Réinitialisation ---
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Réinitialiser les paramètres'),
                  onPressed: () => _confirmReset(context, s),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context, SettingsService s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Réinitialiser ?'),
        content: const Text(
          'Tous les paramètres d\'apparence et de carte reviendront à leur valeur par défaut.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Réinitialiser'),
          ),
        ],
      ),
    );
    if (ok == true) await s.reset();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

class _SubTitle extends StatelessWidget {
  const _SubTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final AccentColor accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: accent.label,
      child: InkResponse(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: accent.color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 3,
            ),
          ),
          child: selected
              ? const Icon(Icons.check, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}


/// Liste des voix françaises installées sur l'appareil, avec aperçu.
class _VoiceSection extends StatefulWidget {
  const _VoiceSection();

  @override
  State<_VoiceSection> createState() => _VoiceSectionState();
}

class _VoiceSectionState extends State<_VoiceSection> {
  final FlutterTts _tts = FlutterTts();
  late final Future<List<Map<String, String>>> _voices = _loadVoices();

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<List<Map<String, String>>> _loadVoices() async {
    try {
      final raw = await _tts.getVoices;
      if (raw is! List) return [];
      final voices = <Map<String, String>>[];
      for (final v in raw) {
        if (v is! Map) continue;
        final name = v['name']?.toString();
        final locale = v['locale']?.toString();
        if (name == null || locale == null) continue;
        final norm = locale.toLowerCase().replaceAll('_', '-');
        if (!norm.startsWith('fr')) continue;
        voices.add({'name': name, 'locale': locale});
      }
      voices.sort((a, b) {
        final c = a['locale']!.compareTo(b['locale']!);
        return c != 0 ? c : a['name']!.compareTo(b['name']!);
      });
      return voices;
    } catch (_) {
      return [];
    }
  }

  String _region(String locale) {
    switch (locale.toLowerCase().replaceAll('_', '-')) {
      case 'fr-fr':
        return 'France';
      case 'fr-ca':
        return 'Canada';
      case 'fr-be':
        return 'Belgique';
      case 'fr-ch':
        return 'Suisse';
      default:
        return locale;
    }
  }

  // Android : noms techniques (ex. fr-fr-x-frd-local) → « Voix N ».
  // iOS : vrais prénoms (Amélie, Thomas...) → affichés tels quels.
  String _label(Map<String, String> v, int index) {
    final name = v['name']!;
    final technical =
        name.contains('-x-') || name.contains('#') || name.contains('_');
    final region = _region(v['locale']!);
    return technical ? 'Voix ${index + 1} — $region' : '$name — $region';
  }

  Future<void> _apercu(String? name, String? locale) async {
    try {
      await _tts.stop();
      await _tts.setSpeechRate(0.5);
      if (name != null && locale != null) {
        await _tts.setVoice({'name': name, 'locale': locale});
      } else {
        await _tts.setLanguage('fr-FR');
      }
      await _tts.speak('Bonjour, voici un aperçu de cette voix.');
    } catch (_) {
      // Aperçu non disponible : on ignore silencieusement.
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    final primary = Theme.of(context).colorScheme.primary;

    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        return FutureBuilder<List<Map<String, String>>>(
          future: _voices,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final voices = snap.data ?? [];

            return Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.record_voice_over_outlined),
                  title: const Text('Voix par défaut du système'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.play_arrow),
                        tooltip: 'Écouter',
                        onPressed: () => _apercu(null, null),
                      ),
                      if (s.voiceName == null) Icon(Icons.check, color: primary),
                    ],
                  ),
                  onTap: () {
                    s.setVoice(null, null);
                    _apercu(null, null);
                  },
                ),
                for (var i = 0; i < voices.length; i++)
                  ListTile(
                    leading: const Icon(Icons.record_voice_over_outlined),
                    title: Text(_label(voices[i], i)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.play_arrow),
                          tooltip: 'Écouter',
                          onPressed: () => _apercu(
                              voices[i]['name'], voices[i]['locale']),
                        ),
                        if (s.voiceName == voices[i]['name'] &&
                            s.voiceLocale == voices[i]['locale'])
                          Icon(Icons.check, color: primary),
                      ],
                    ),
                    onTap: () {
                      s.setVoice(voices[i]['name'], voices[i]['locale']);
                      _apercu(voices[i]['name'], voices[i]['locale']);
                    },
                  ),
                if (voices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      'Aucune voix française détectée sur cet appareil : '
                      'la voix par défaut du système sera utilisée.',
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}