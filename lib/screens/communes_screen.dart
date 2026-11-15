import 'dart:math' as math;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../models/poi_models.dart';

/// Une commune couverte par FaYoW, avec ses compteurs pour l'utilisateur.
/// Renvoyée par [CommunesScreen] quand l'utilisateur touche une commune.
class CommuneFayow {
  final String nom;
  final String departement;
  final String region;
  final String pays;

  /// Nombre d'anecdotes validées dans la commune.
  final int nbAnecdotes;

  /// Nombre d'anecdotes validées déjà lues par l'utilisateur.
  final int nbLues;

  /// Positions des anecdotes validées : servent à cadrer la carte.
  final List<LatLng> points;

  const CommuneFayow({
    required this.nom,
    required this.departement,
    required this.region,
    required this.pays,
    required this.nbAnecdotes,
    required this.nbLues,
    required this.points,
  });
}

/// Accumulateur interne pendant le regroupement des POIs.
class _Cumul {
  final String nom;
  final String departement;
  final String region;
  final String pays;
  int total = 0;
  int lues = 0;
  final List<LatLng> points = [];

  _Cumul(this.nom, this.departement, this.region, this.pays);

  CommuneFayow toCommune() => CommuneFayow(
        nom: nom,
        departement: departement,
        region: region,
        pays: pays,
        nbAnecdotes: total,
        nbLues: lues,
        points: points,
      );
}

class CommunesScreen extends StatefulWidget {
  final List<PointInteret> pointsInteret;
  final Set<String> poisLusIds;

  const CommunesScreen({
    super.key,
    required this.pointsInteret,
    required this.poisLusIds,
  });

  @override
  State<CommunesScreen> createState() => _CommunesScreenState();
}

class _CommunesScreenState extends State<CommunesScreen> {
  static const String _paysInconnu = 'Pays inconnu';
  static const String _regionInconnue = 'Région inconnue';
  static const double _largeurAnecdotes = 84;
  static const double _largeurLues = 56;

  late final List<CommuneFayow> _communes;

  /// Anecdotes validées dont la commune n'est pas (encore) identifiée.
  int _sansCommune = 0;

  String? _paysFiltre;
  final Set<String> _regionsFiltre = {};

  @override
  void initState() {
    super.initState();
    _calculerCommunes();
  }

  // -------------------------------------------------------------------------
  // Regroupement des anecdotes par commune
  // -------------------------------------------------------------------------

  void _calculerCommunes() {
    final groupes = <String, _Cumul>{};
    var sansCommune = 0;

    for (final poi in widget.pointsInteret) {
      if (poi.status != PoiStatus.validated) continue;

      final nom = (poi.commune ?? '').trim();
      if (nom.isEmpty) {
        sansCommune++;
        continue;
      }
      final departement = (poi.departement ?? '').trim();
      final region = (poi.region ?? '').trim();
      final pays = (poi.pays ?? '').trim();

      final cle = '$pays|$region|$departement|$nom';
      final cumul = groupes.putIfAbsent(
        cle,
        () => _Cumul(
          nom,
          departement,
          region.isEmpty ? _regionInconnue : region,
          pays.isEmpty ? _paysInconnu : pays,
        ),
      );
      cumul.total++;
      if (widget.poisLusIds.contains(poi.id)) cumul.lues++;
      cumul.points.add(poi.position);
    }

    _communes = groupes.values.map((c) => c.toCommune()).toList();
    _sansCommune = sansCommune;
  }

  // -------------------------------------------------------------------------
  // Tri (insensible aux accents : « Île-de-France » entre I et J, pas après Z)
  // -------------------------------------------------------------------------

  static String _sansAccents(String s) {
    const de = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿœæ';
    const vers = 'aaaaaaceeeeiiiinooooouuuuyyoa';
    final tampon = StringBuffer();
    for (final lettre in s.toLowerCase().split('')) {
      final i = de.indexOf(lettre);
      tampon.write(i >= 0 ? vers[i] : lettre);
    }
    return tampon.toString();
  }

  static int _comparer(String a, String b) =>
      _sansAccents(a).compareTo(_sansAccents(b));

  // -------------------------------------------------------------------------
  // Filtres
  // -------------------------------------------------------------------------

  bool get _filtreActif => _paysFiltre != null || _regionsFiltre.isNotEmpty;

  List<CommuneFayow> get _communesFiltrees {
    return _communes.where((c) {
      if (_paysFiltre != null && c.pays != _paysFiltre) return false;
      if (_regionsFiltre.isNotEmpty && !_regionsFiltre.contains(c.region)) {
        return false;
      }
      return true;
    }).toList();
  }

  List<String> get _paysDisponibles {
    final pays = _communes.map((c) => c.pays).toSet().toList();
    pays.sort(_comparer);
    return pays;
  }

  List<String> get _regionsDisponibles {
    final regions = _communes
        .where((c) => _paysFiltre == null || c.pays == _paysFiltre)
        .map((c) => c.region)
        .toSet()
        .toList();
    regions.sort(_comparer);
    return regions;
  }

  void _ouvrirFiltres() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) {
          // Applique le changement à l'écran ET à la feuille
          void modifier(VoidCallback f) {
            setState(f);
            setSheet(() {});
          }

          final pays = _paysDisponibles;
          final regions = _regionsDisponibles;

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Filtrer les communes',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  const Text('Pays',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      ChoiceChip(
                        label: const Text('Tous'),
                        selected: _paysFiltre == null,
                        onSelected: (_) => modifier(() {
                          _paysFiltre = null;
                          _regionsFiltre.clear();
                        }),
                      ),
                      for (final p in pays)
                        ChoiceChip(
                          label: Text(p),
                          selected: _paysFiltre == p,
                          onSelected: (_) => modifier(() {
                            _paysFiltre = p;
                            _regionsFiltre.clear();
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Régions',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final r in regions)
                        FilterChip(
                          label: Text(r),
                          selected: _regionsFiltre.contains(r),
                          onSelected: (selection) => modifier(() {
                            if (selection) {
                              _regionsFiltre.add(r);
                            } else {
                              _regionsFiltre.remove(r);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      TextButton(
                        onPressed: _filtreActif
                            ? () => modifier(() {
                                  _paysFiltre = null;
                                  _regionsFiltre.clear();
                                })
                            : null,
                        child: const Text('Réinitialiser'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: Text(
                            'Voir ${_communesFiltrees.length} commune${_communesFiltrees.length > 1 ? 's' : ''}'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Éléments du tableau
  // -------------------------------------------------------------------------

  String _resume(List<CommuneFayow> communes) {
    final nbCommunes = communes.length;
    final anecdotes = communes.fold<int>(0, (s, c) => s + c.nbAnecdotes);
    final lues = communes.fold<int>(0, (s, c) => s + c.nbLues);
    return '$nbCommunes commune${nbCommunes > 1 ? 's' : ''} · '
        '$anecdotes anecdote${anecdotes > 1 ? 's' : ''} · $lues lue${lues > 1 ? 's' : ''}';
  }

  Widget _entetePays(String pays, List<CommuneFayow> communes) {
    final couleur = Theme.of(context).colorScheme.primary;
    return Container(
      width: double.infinity,
      color: couleur.withOpacity(0.16),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pays,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: couleur,
            ),
          ),
          Text(
            _resume(communes),
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _enteteRegion(String region, List<CommuneFayow> communes) {
    return Container(
      width: double.infinity,
      color: Colors.blueGrey.withOpacity(0.08),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              region,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.blueGrey,
              ),
            ),
          ),
          Text(
            '${communes.length} commune${communes.length > 1 ? 's' : ''}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _enteteColonnes() {
    const style = TextStyle(fontSize: 12, fontWeight: FontWeight.bold);
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: const Row(
        children: [
          Expanded(child: Text('Commune', style: style)),
          SizedBox(
            width: _largeurAnecdotes,
            child: Text('Anecdotes', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: _largeurLues,
            child: Text('Lues', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  Widget _ligneCommune(CommuneFayow c) {
    final toutLu = c.nbAnecdotes > 0 && c.nbLues == c.nbAnecdotes;
    return InkWell(
      onTap: () => Navigator.pop(context, c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.nom, style: const TextStyle(fontSize: 15)),
                  if (c.departement.isNotEmpty)
                    Text(
                      c.departement,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: _largeurAnecdotes,
              child: Text(
                '${c.nbAnecdotes}',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 15),
              ),
            ),
            SizedBox(
              width: _largeurLues,
              child: Text(
                '${c.nbLues}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: toutLu ? FontWeight.bold : FontWeight.normal,
                  color: toutLu ? Colors.green : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Corps de l'écran
  // -------------------------------------------------------------------------

  Widget _buildTableau() {
    final communes = _communesFiltrees;

    if (communes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _communes.isEmpty
                ? 'Aucune commune identifiée pour le moment.'
                : 'Aucune commune ne correspond à ces filtres.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ),
      );
    }

    // pays -> région -> communes
    final parPays = <String, Map<String, List<CommuneFayow>>>{};
    for (final c in communes) {
      parPays
          .putIfAbsent(c.pays, () => {})
          .putIfAbsent(c.region, () => [])
          .add(c);
    }

    final lignes = <Widget>[];
    final paysTries = parPays.keys.toList()..sort(_comparer);
    for (final pays in paysTries) {
      final regions = parPays[pays]!;
      lignes.add(_entetePays(pays, regions.values.expand((l) => l).toList()));

      final regionsTriees = regions.keys.toList()..sort(_comparer);
      for (final region in regionsTriees) {
        final liste = regions[region]!
          ..sort((a, b) => _comparer(a.nom, b.nom));
        lignes.add(_enteteRegion(region, liste));
        for (var i = 0; i < liste.length; i++) {
          if (i > 0) lignes.add(const Divider(height: 1, indent: 16));
          lignes.add(_ligneCommune(liste[i]));
        }
      }
    }

    if (_sansCommune > 0) {
      lignes.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text(
          '$_sansCommune anecdote${_sansCommune > 1 ? 's' : ''} validée'
          '${_sansCommune > 1 ? 's' : ''} sans commune identifiée '
          '(non comptée${_sansCommune > 1 ? 's' : ''} ci-dessus).',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ));
    }

    // Marge basse : la dernière ligne ne doit pas passer sous la barre de
    // navigation Android (même logique que l'onglet Liste de ParcourirScreen).
    final insetBas = MediaQuery.of(context).viewPadding.bottom;
    final margeBasse = (defaultTargetPlatform == TargetPlatform.android
            ? math.max(insetBas, 48.0)
            : insetBas) +
        16;

    return Column(
      children: [
        _enteteColonnes(),
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(bottom: margeBasse),
            children: lignes,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('Communes FaYoW'),
        ),
        actions: [
          IconButton(
            tooltip: 'Filtrer par pays et régions',
            onPressed: _communes.isEmpty ? null : _ouvrirFiltres,
            icon: Badge(
              smallSize: 8,
              isLabelVisible: _filtreActif,
              child: const Icon(Icons.filter_list),
            ),
          ),
        ],
      ),
      body: _buildTableau(),
    );
  }
}