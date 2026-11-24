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

/// Critère de tri du tableau (choisi en touchant l'en-tête des colonnes).
enum _CritereTri { anecdotes, lues, alphabetique }

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

  // Tri : par défaut, les lieux les plus riches en anecdotes d'abord.
  _CritereTri _critereTri = _CritereTri.anecdotes;
  bool _triDecroissant = true;

  // État de dépliage : les pays sont dépliés par défaut (on ne mémorise que
  // ceux que l'utilisateur a repliés), les régions sont repliées par défaut
  // (on ne mémorise que celles qu'il a dépliées).
  final Set<String> _paysReplies = {};
  final Set<String> _regionsDepliees = {};

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

  /// Touche un critère de l'en-tête : s'il est déjà actif on inverse le sens,
  /// sinon on l'active avec son sens naturel (décroissant pour les compteurs,
  /// croissant pour l'ordre alphabétique).
  void _changerTri(_CritereTri critere) {
    setState(() {
      if (_critereTri == critere) {
        _triDecroissant = !_triDecroissant;
      } else {
        _critereTri = critere;
        _triDecroissant = critere != _CritereTri.alphabetique;
      }
    });
  }

  /// Compare deux éléments (pays, régions ou communes) selon le critère de tri
  /// courant. Un pays ou une région est représenté(e) par la liste de ses
  /// communes, une commune par une liste d'un seul élément. En cas d'égalité,
  /// l'ordre alphabétique croissant départage.
  int _comparerAgregats(
    String nomA,
    List<CommuneFayow> a,
    String nomB,
    List<CommuneFayow> b,
  ) {
    if (_critereTri == _CritereTri.alphabetique) {
      final r = _comparer(nomA, nomB);
      return _triDecroissant ? -r : r;
    }

    final r = _critereTri == _CritereTri.anecdotes
        ? _sommeAnecdotes(a).compareTo(_sommeAnecdotes(b))
        : _sommeLues(a).compareTo(_sommeLues(b));
    if (r != 0) return _triDecroissant ? -r : r;
    return _comparer(nomA, nomB);
  }

  // -------------------------------------------------------------------------
  // Utilitaires d'affichage
  // -------------------------------------------------------------------------

  static String _pluriel(int n, String mot) => '$n $mot${n > 1 ? 's' : ''}';

  static int _sommeAnecdotes(List<CommuneFayow> l) =>
      l.fold<int>(0, (s, c) => s + c.nbAnecdotes);

  static int _sommeLues(List<CommuneFayow> l) =>
      l.fold<int>(0, (s, c) => s + c.nbLues);

  static String _cleRegion(String pays, String region) => '$pays|$region';

  /// Texte d'une colonne de nombres : il se réduit au besoin pour tenir dans
  /// la colonne, au lieu de déborder quand la police système est agrandie.
  Widget _nombre(String texte, TextStyle style) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(texte, style: style),
    );
  }

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

  /// Déplie la région choisie dans le filtre : si on filtre sur une région,
  /// c'est pour voir ses communes.
  void _deplierRegion(String region) {
    for (final c in _communes) {
      if (c.region == region && (_paysFiltre == null || c.pays == _paysFiltre)) {
        _regionsDepliees.add(_cleRegion(c.pays, region));
      }
    }
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
                              _deplierRegion(r);
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
                            'Voir ${_pluriel(_communesFiltrees.length, 'commune')}'),
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

  /// Une cellule cliquable de l'en-tête : texte + flèche si c'est le critère
  /// de tri actif. Le contenu se réduit si besoin pour ne jamais être tronqué
  /// (police système agrandie).
  Widget _celluleEntete({
    required String libelle,
    required _CritereTri critere,
    required Alignment alignement,
  }) {
    final actif = _critereTri == critere;
    final couleur = actif
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: () => _changerTri(critere),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignement,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                libelle,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: couleur,
                ),
              ),
              if (actif)
                Icon(
                  _triDecroissant ? Icons.arrow_downward : Icons.arrow_upward,
                  size: 14,
                  color: couleur,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _enteteColonnes() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: _celluleEntete(
              libelle: 'Pays › Région › Commune',
              critere: _CritereTri.alphabetique,
              alignement: Alignment.centerLeft,
            ),
          ),
          SizedBox(
            width: _largeurAnecdotes,
            child: _celluleEntete(
              libelle: 'Anecdotes',
              critere: _CritereTri.anecdotes,
              alignement: Alignment.centerRight,
            ),
          ),
          SizedBox(
            width: _largeurLues,
            child: _celluleEntete(
              libelle: 'Lues',
              critere: _CritereTri.lues,
              alignement: Alignment.centerRight,
            ),
          ),
        ],
      ),
    );
  }

  /// Ligne de pays ou de région : nom, détail, flèche de dépliage, et les
  /// sommes d'anecdotes et de lues dans les mêmes colonnes que les communes.
  Widget _ligneAgregat({
    required String titre,
    required String detail,
    required int anecdotes,
    required int lues,
    required bool deplie,
    required VoidCallback onTap,
    required Color fond,
    required Color couleur,
    required double tailleTitre,
    required double margeGauche,
  }) {
    final toutLu = anecdotes > 0 && lues == anecdotes;
    return Material(
      color: fond,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(margeGauche, 10, 16, 10),
          child: Row(
            children: [
              Icon(
                deplie ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: couleur,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titre,
                      style: TextStyle(
                        fontSize: tailleTitre,
                        fontWeight: FontWeight.bold,
                        color: couleur,
                      ),
                    ),
                    Text(
                      detail,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: _largeurAnecdotes,
                child: _nombre(
                  '$anecdotes',
                  TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: couleur,
                  ),
                ),
              ),
              SizedBox(
                width: _largeurLues,
                child: _nombre(
                  '$lues',
                  TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: toutLu ? Colors.green : couleur,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lignePays({
    required String pays,
    required int nbRegions,
    required List<CommuneFayow> communes,
    required bool deplie,
  }) {
    final couleur = Theme.of(context).colorScheme.primary;
    return _ligneAgregat(
      titre: pays,
      detail: '${_pluriel(nbRegions, 'région')} · '
          '${_pluriel(communes.length, 'commune')}',
      anecdotes: _sommeAnecdotes(communes),
      lues: _sommeLues(communes),
      deplie: deplie,
      onTap: () => setState(() {
        if (!_paysReplies.remove(pays)) _paysReplies.add(pays);
      }),
      fond: couleur.withOpacity(0.16),
      couleur: couleur,
      tailleTitre: 16,
      margeGauche: 12,
    );
  }

  Widget _ligneRegion({
    required String pays,
    required String region,
    required List<CommuneFayow> communes,
    required bool deplie,
  }) {
    final cle = _cleRegion(pays, region);
    return _ligneAgregat(
      titre: region,
      detail: _pluriel(communes.length, 'commune'),
      anecdotes: _sommeAnecdotes(communes),
      lues: _sommeLues(communes),
      deplie: deplie,
      onTap: () => setState(() {
        if (!_regionsDepliees.remove(cle)) _regionsDepliees.add(cle);
      }),
      fond: Colors.blueGrey.withOpacity(0.08),
      couleur: Colors.blueGrey.shade700,
      tailleTitre: 14,
      margeGauche: 24,
    );
  }

  Widget _ligneCommune(CommuneFayow c) {
    final toutLu = c.nbAnecdotes > 0 && c.nbLues == c.nbAnecdotes;
    return InkWell(
      onTap: () => Navigator.pop(context, c),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(56, 10, 16, 10),
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
              child: _nombre(
                '${c.nbAnecdotes}',
                const TextStyle(fontSize: 15),
              ),
            ),
            SizedBox(
              width: _largeurLues,
              child: _nombre(
                '${c.nbLues}',
                TextStyle(
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

    List<CommuneFayow> toutesLesCommunes(String pays) =>
        parPays[pays]!.values.expand((l) => l).toList();

    final lignes = <Widget>[];
    final paysTries = parPays.keys.toList()
      ..sort((a, b) => _comparerAgregats(
            a,
            toutesLesCommunes(a),
            b,
            toutesLesCommunes(b),
          ));
    for (final pays in paysTries) {
      final regions = parPays[pays]!;
      final paysDeplie = !_paysReplies.contains(pays);
      lignes.add(_lignePays(
        pays: pays,
        nbRegions: regions.length,
        communes: toutesLesCommunes(pays),
        deplie: paysDeplie,
      ));
      if (!paysDeplie) continue;

      final regionsTriees = regions.keys.toList()
        ..sort((a, b) => _comparerAgregats(a, regions[a]!, b, regions[b]!));
      for (final region in regionsTriees) {
        final liste = regions[region]!
          ..sort((a, b) => _comparerAgregats(a.nom, [a], b.nom, [b]));
        final regionDeplie =
            _regionsDepliees.contains(_cleRegion(pays, region));
        lignes.add(_ligneRegion(
          pays: pays,
          region: region,
          communes: liste,
          deplie: regionDeplie,
        ));
        if (!regionDeplie) continue;

        for (var i = 0; i < liste.length; i++) {
          if (i > 0) lignes.add(const Divider(height: 1, indent: 56));
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