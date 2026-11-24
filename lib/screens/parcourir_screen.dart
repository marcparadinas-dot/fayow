import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/poi_models.dart';
import '../repository/poi_repository.dart';
import '../services/auth_service.dart';
import '../services/score_service.dart';
import '../services/settings_service.dart';
import 'classement_screen.dart';
import 'communes_screen.dart';
import '../services/mail_service.dart';
import '../utils/distance_format.dart';
import '../widgets/map_compass_button.dart';
import '../widgets/map_recenter_button.dart';
import '../widgets/map_legende_button.dart'; // LÉGENDE
import '../widgets/confirmation_soumission.dart';
import '../widgets/direction_marker.dart';

/// Filtre d'affichage de l'onglet Liste
enum _FiltreListe { tout, lus, proposes, inities }

/// Anecdotes validées DONT JE SUIS L'AUTEUR et que j'ai lues : vert foncé.
const Color _couleurMienneLue = Color(0xFF1B5E20);

/// Anecdotes validées DONT JE SUIS L'AUTEUR et que je n'ai pas lues : parme.
/// [_couleurMienneNonLueFonce] est une variante plus soutenue, utilisée pour
/// les bordures et les textes, où le parme seul manquerait de contraste.
/// (Le violet est réservé à l'écran principal, map_screen.dart.)
const Color _couleurMienneNonLue = Color(0xFFC9A0DC);
const Color _couleurMienneNonLueFonce = Color(0xFF9B6FB5);

/// Rayon réel de la zone d'une anecdote (en mètres).
const double _rayonCercleMetres = 20.0;

/// Rayon minimal affiché à l'écran (en pixels) : quand le zoom est tel que
/// 20 m représenteraient moins que cela, le cercle garde cette taille au lieu
/// de devenir un minuscule point (comme sur l'interface de gestion).
const double _rayonMinPixels = 9.0;

class ParcourirScreen extends StatefulWidget {
  final LatLng positionInitiale;
  final List<PointInteret> pointsInteret;
  final Set<String> poisLusIds;

  const ParcourirScreen({
    super.key,
    required this.positionInitiale,
    required this.pointsInteret,
    required this.poisLusIds,
  });

  @override
  State<ParcourirScreen> createState() => _ParcourirScreenState();
}

class _ParcourirScreenState extends State<ParcourirScreen>
    with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  final PoiRepository _poiRepository = PoiRepository();
  final Distance _distance = const Distance();

  late TabController _tabController;
  late List<PointInteret> _pointsInteret;
  late Set<String> _poisLusIds;
  late bool _isModerator;
  Map<String, DateTime> _datesLecture = {};

  // Anecdote à localiser : mémorisée car TabBarView reconstruit l'onglet
  // Carte (et donc la FlutterMap) à chaque retour dessus.
  LatLng? _cibleLocalisation;
  static const double _zoomLocalisation = 18.0;

  // Zoom courant de la carte (arrondi au quart de niveau) : sert à choisir,
  // pour chaque cercle, entre rayon en mètres et rayon minimal en pixels.
  // ValueNotifier : seule la couche des cercles est reconstruite.
  final ValueNotifier<double> _zoomCarte = ValueNotifier<double>(16.0);

  // Position de l'utilisateur (mise à jour en continu) : sert au bouton de
  // recentrage, qui n'apparaît que si la carte s'en éloigne.
  late LatLng _positionUtilisateur;
  StreamSubscription<Position>? _positionSubscription;

  // Onglet Liste : filtre actif et contrôleur de défilement (ascenseur)
  _FiltreListe _filtreListe = _FiltreListe.tout;
  final ScrollController _listeController = ScrollController();
  StreamSubscription<CompassEvent>? _compassSubscription;
  // Orientation de l'utilisateur (0 = nord). ValueNotifier : seul le marqueur
  // est reconstruit quand le cap change, pas tout l'écran.
  final ValueNotifier<double> _cap = ValueNotifier<double>(0.0);

  // Déplacement en deux étapes
  bool _modeSelectionPosition = false;
  PointInteret? _poiADeplacer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _pointsInteret = List.from(widget.pointsInteret);
    _poisLusIds = Set.from(widget.poisLusIds);
    _isModerator = AuthService.isModerator;
    _positionUtilisateur = widget.positionInitiale;
    _suivrePositionUtilisateur();
    _suivreCap();
    _chargerDatesLecture();
  }

  /// Cap de l'utilisateur via flutter_compass (iOS et Android), comme sur la
  /// carte principale (voir MapScreen).
  void _suivreCap() {
    _compassSubscription = FlutterCompass.events?.listen((event) {
      final heading = event.heading;
      if (!mounted || heading == null) return;
      // On ignore les variations inférieures à 2° (capteur Android très bavard)
      final ecart = ((heading - _cap.value + 540) % 360) - 180;
      if (ecart.abs() < 2.0) return;
      _cap.value = heading;
    });
  }

  void _suivrePositionUtilisateur() {
    try {
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen(
        (position) {
          if (!mounted) return;
          setState(() {
            _positionUtilisateur =
                LatLng(position.latitude, position.longitude);
          });
        },
        onError: (_) {
          // GPS indisponible : on garde la dernière position connue
        },
      );
    } catch (_) {
      // Permission absente : on garde la position initiale
    }
  }

  /// Recentre la carte sur l'utilisateur en conservant le niveau de zoom
  void _recentrerSurUtilisateur() {
    setState(() => _cibleLocalisation = null);
    _mapController.move(_positionUtilisateur, _mapController.camera.zoom);
  }

  Future<void> _chargerDatesLecture() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final dates = await _poiRepository.chargerDatesLecture(uid);
    if (mounted) {
      setState(() => _datesLecture = dates);
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();
    _cap.dispose();
    _zoomCarte.dispose();
    _listeController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Anecdotes validées : auteur et statut de lecture
  // -------------------------------------------------------------------------

  /// Vrai si le POI est validé et a été créé par l'utilisateur connecté
  /// (qu'il l'ait lu ou non).
  bool _estMonPoiValide(PointInteret poi) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return uid != null &&
        poi.status == PoiStatus.validated &&
        poi.creatorUid == uid;
  }

  /// Vrai si le POI est validé et marqué comme lu par l'utilisateur.
  bool _estLu(PointInteret poi) {
    return poi.status == PoiStatus.validated && _poisLusIds.contains(poi.id);
  }

  // -------------------------------------------------------------------------
  // POIs visibles (filtrés selon le profil)
  // -------------------------------------------------------------------------

  /// POIs affichés comme cercles sur la carte : tous les statuts, pour
  /// tout le monde. Un utilisateur lambda voit un cercle gris sur un
  /// validé non lu créé par un tiers, mais sans accès à son texte
  /// (cf. _ouvrirDialogPoi).
  List<PointInteret> get _poisVisibles {
    return List<PointInteret>.from(_pointsInteret);
  }

  /// POIs affichés dans l'onglet Liste (avec aperçu du texte) : on masque
  /// les validés non lus aux non-modérateurs pour ne pas dévoiler le
  /// contenu d'une anecdote avant que l'utilisateur ne se rende sur place.
  /// Exception : l'auteur d'une anecdote validée peut toujours la consulter.
  List<PointInteret> get _poisListe {
    return _pointsInteret.where((poi) {
      if (poi.status == PoiStatus.validated) {
        return _poisLusIds.contains(poi.id) ||
            _isModerator ||
            _estMonPoiValide(poi);
      }
      return true;
    }).toList();
  }

  bool _correspondAuFiltre(PointInteret poi) {
    switch (_filtreListe) {
      case _FiltreListe.tout:
        return true;
      case _FiltreListe.lus:
        // Vert normal (tiers lus) et vert foncé (mes anecdotes lues)
        return _estLu(poi);
      case _FiltreListe.proposes:
        // Proposées, puis (en dessous) mes anecdotes validées
        // (parme si non lues, vert foncé si lues)
        return poi.status == PoiStatus.proposed || _estMonPoiValide(poi);
      case _FiltreListe.inities:
        return poi.status == PoiStatus.initiated;
    }
  }

  // POIs triés : validés lus ou à moi (récent → ancien), puis proposés,
  // puis initiés. Avec le filtre "Proposées" : proposés d'abord, puis mes
  // anecdotes validées.
  List<PointInteret> get _poisTries {
    final liste = _poisListe.where(_correspondAuFiltre).toList();
    final modeProposees = _filtreListe == _FiltreListe.proposes;
    liste.sort((a, b) {
      int ordreStatut(PointInteret p) {
        if (modeProposees) {
          return p.status == PoiStatus.proposed ? 0 : 1;
        }
        if (p.status == PoiStatus.validated &&
            (_poisLusIds.contains(p.id) || _estMonPoiValide(p))) {
          return 0;
        }
        if (p.status == PoiStatus.proposed) return 1;
        if (p.status == PoiStatus.initiated) return 2;
        if (p.status == PoiStatus.validated) return 3; // validés non lus (modérateur)
        return 4;
      }

      final ordreA = ordreStatut(a);
      final ordreB = ordreStatut(b);
      if (ordreA != ordreB) return ordreA.compareTo(ordreB);

      // Parmi les anecdotes validées : la plus récemment découverte en premier
      final groupeValidees = modeProposees ? ordreA == 1 : ordreA == 0;
      if (groupeValidees) {
        final dateA = _datesLecture[a.id];
        final dateB = _datesLecture[b.id];
        if (dateA != null && dateB != null) return dateB.compareTo(dateA);
        if (dateA != null) return -1;
        if (dateB != null) return 1;
      }
      return 0;
    });
    return liste;
  }

  // -------------------------------------------------------------------------
  // Couleurs
  //
  // Anecdotes validées :
  //   - créée par un tiers, non lue : gris (texte inaccessible)
  //   - créée par un tiers, lue     : vert normal
  //   - créée par moi, non lue      : parme
  //   - créée par moi, lue          : vert foncé
  // -------------------------------------------------------------------------

  Color _getCercleColor(PointInteret poi) {
    if (poi.status == PoiStatus.validated) {
      if (_estMonPoiValide(poi)) {
        return (_estLu(poi) ? _couleurMienneLue : _couleurMienneNonLue)
            .withOpacity(0.55);
      }
      if (_estLu(poi)) return Colors.green.withOpacity(0.4);
      return Colors.grey.withOpacity(0.5);
    }
    if (poi.status == PoiStatus.initiated) {
      return Colors.orange.withOpacity(0.5);
    }
    return Colors.blue[900]!.withOpacity(0.5); // proposed
  }

  Color _getCercleBorderColor(PointInteret poi) {
    if (poi.status == PoiStatus.validated) {
      if (_estMonPoiValide(poi)) {
        return _estLu(poi) ? _couleurMienneLue : _couleurMienneNonLueFonce;
      }
      if (_estLu(poi)) return Colors.green;
      return Colors.grey;
    }
    if (poi.status == PoiStatus.initiated) return Colors.orange;
    return Colors.blue[900]!; // proposed
  }

  Color _getListeColor(PointInteret poi) {
    if (poi.status == PoiStatus.validated) {
      if (_estMonPoiValide(poi)) {
        return _estLu(poi) ? _couleurMienneLue : _couleurMienneNonLueFonce;
      }
      if (_estLu(poi)) return Colors.green;
      return Colors.grey;
    }
    if (poi.status == PoiStatus.proposed) return Colors.blue[900]!;
    return Colors.orange;
  }

  String _getStatutLabel(PointInteret poi) {
    if (_estLu(poi)) return 'Lue';
    if (poi.status == PoiStatus.validated) return 'Validée';
    if (poi.status == PoiStatus.proposed) return 'Proposée';
    return 'Brouillon';
  }

  // LÉGENDE -----------------------------------------------------------------
  /// Légende affichée par le bouton « i » de la carte. Les couleurs reprennent
  /// celles de _getCercleColor / _getCercleBorderColor : à modifier ensemble.
  List<LegendeEntree> get _entreesLegende => [
        LegendeEntree(
          couleurFond: Colors.grey.withOpacity(0.5),
          couleurBordure: Colors.grey,
          titre: 'Anecdote à découvrir',
          description:
              "Écrite par un autre utilisateur. Rendez-vous sur place pour la lire.",
        ),
        LegendeEntree(
          couleurFond: _couleurMienneNonLue.withOpacity(0.55),
          couleurBordure: _couleurMienneNonLueFonce,
          titre: 'Mon anecdote validée, non lue',
          description: "Vous pouvez la consulter, mais elle ne compte pas "
              "dans votre score : rendez-vous sur place.",
        ),
        LegendeEntree(
          couleurFond: Colors.green.withOpacity(0.4),
          couleurBordure: Colors.green,
          titre: 'Anecdote découverte',
          description: "Écrite par un autre utilisateur, déjà lue.",
        ),
        LegendeEntree(
          couleurFond: _couleurMienneLue.withOpacity(0.55),
          couleurBordure: _couleurMienneLue,
          titre: 'Mon anecdote validée, lue',
          description: "Votre anecdote, déjà lue sur place.",
        ),
        LegendeEntree(
          couleurFond: Colors.blue[900]!.withOpacity(0.5),
          couleurBordure: Colors.blue[900]!,
          titre: 'Anecdote proposée',
          description: "En cours de modération. Visible par vous et les modérateurs.",
        ),
        LegendeEntree(
          couleurFond: Colors.orange.withOpacity(0.5),
          couleurBordure: Colors.orange,
          titre: 'Brouillon',
          description: "Visible uniquement par vous, pas encore proposée.",
        ),
      ];

  // -------------------------------------------------------------------------
  // Taille des cercles selon le zoom
  // -------------------------------------------------------------------------

  /// Nombre de mètres représentés par un pixel à ce zoom et cette latitude
  /// (projection Web Mercator, tuiles de 256 px).
  double _metresParPixel(double zoom, double latitude) {
    return 156543.03392 *
        math.cos(latitude * math.pi / 180) /
        math.pow(2, zoom);
  }

  /// Distance (en mètres) à partir de laquelle un tap est rattaché à un point.
  /// 30 m en zoom rapproché ; plus large au dézoom, pour que les points
  /// agrandis (rayon minimal en pixels) restent faciles à toucher.
  double _seuilToucheMetres(LatLng pointTape) {
    double zoom;
    try {
      zoom = _mapController.camera.zoom;
    } catch (_) {
      return 30.0;
    }
    final mpp = _metresParPixel(zoom, pointTape.latitude);
    return math.max(30.0, _rayonMinPixels * 1.5 * mpp);
  }

  // -------------------------------------------------------------------------
  // Construction des cercles (carte)
  // -------------------------------------------------------------------------

  List<CircleMarker> _buildCercles(double zoom) {
    final cercles = <CircleMarker>[];
    for (final poi in _poisVisibles) {
      final enDeplacement = _poiADeplacer?.id == poi.id;

      // Au zoom rapproché, le cercle garde son rayon réel (20 m). Dès que
      // 20 m représentent moins que _rayonMinPixels à l'écran, on passe en
      // rayon fixe en pixels pour que le point reste bien visible.
      final metresParPixel = _metresParPixel(zoom, poi.position.latitude);
      final enMetres = _rayonCercleMetres / metresParPixel >= _rayonMinPixels;

      cercles.add(CircleMarker(
        point: poi.position,
        radius: enMetres ? _rayonCercleMetres : _rayonMinPixels,
        useRadiusInMeter: enMetres,
        color: enDeplacement
            ? Colors.orange.withOpacity(0.2)
            : _getCercleColor(poi),
        borderColor:
            enDeplacement ? Colors.orange : _getCercleBorderColor(poi),
        borderStrokeWidth: enDeplacement ? 4 : 3,
      ));
    }
    return cercles;
  }

  // -------------------------------------------------------------------------
  // Tap sur la carte
  // -------------------------------------------------------------------------

  void _onCarteTappee(LatLng tapLatLng) {
    if (_modeSelectionPosition && _poiADeplacer != null) {
      _confirmerDeplacement(tapLatLng);
      return;
    }

    final double seuilMetres = _seuilToucheMetres(tapLatLng);
    PointInteret? poiTouche;
    double distanceMin = double.infinity;

    for (final poi in _poisVisibles) {
      final dist = _distance.as(LengthUnit.Meter, tapLatLng, poi.position);
      if (dist < seuilMetres && dist < distanceMin) {
        distanceMin = dist;
        poiTouche = poi;
      }
    }

    if (poiTouche != null) _ouvrirDialogPoi(poiTouche);
  }

  // -------------------------------------------------------------------------
  // Long press → déplacement
  // -------------------------------------------------------------------------

  void _onCarteLongPress(LatLng tapLatLng) {
    final double seuilMetres = _seuilToucheMetres(tapLatLng);
    final uid = FirebaseAuth.instance.currentUser?.uid;

    PointInteret? poiCible;
    double distanceMin = double.infinity;

    for (final poi in _pointsInteret) {
      final deplacable = switch (poi.status) {
        PoiStatus.initiated => poi.creatorUid == uid,
        PoiStatus.validated => _isModerator,
        PoiStatus.proposed => _isModerator,
      };
      if (!deplacable) continue;

      final dist = _distance.as(LengthUnit.Meter, tapLatLng, poi.position);
      if (dist < seuilMetres && dist < distanceMin) {
        distanceMin = dist;
        poiCible = poi;
      }
    }

    if (poiCible == null) return;

    final apercu = poiCible.message.length > 50
        ? '${poiCible.message.substring(0, 50)}...'
        : poiCible.message;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Déplacer ce point ?'),
        content: Text(apercu),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _poiADeplacer = poiCible;
                _modeSelectionPosition = true;
              });
            },
            child: const Text('Déplacer'),
          ),
        ],
      ),
    );
  }

  void _confirmerDeplacement(LatLng nouvellePosition) {
    final poi = _poiADeplacer!;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Confirmer le déplacement ?'),
        content: Text(
          'Lat : ${nouvellePosition.latitude.toStringAsFixed(6)}\n'
          'Lng : ${nouvellePosition.longitude.toStringAsFixed(6)}',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Tapez à nouveau pour choisir une autre position'),
                  duration: Duration(seconds: 3),
                ),
              );
            },
            child: const Text('Choisir ailleurs'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _modeSelectionPosition = false;
                _poiADeplacer = null;
              });
            },
            child: const Text('Annuler',
                style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _modeSelectionPosition = false);
              try {
                await _poiRepository.mettreAJourPoi(poi.id, {
                  'lat': nouvellePosition.latitude,
                  'lng': nouvellePosition.longitude,
                });
                final index =
                    _pointsInteret.indexOfFirst((p) => p.id == poi.id);
                if (index != -1) {
                  setState(() {
                    _pointsInteret[index] = _pointsInteret[index]
                        .copyWith(position: nouvellePosition);
                    _poiADeplacer = null;
                  });
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Position mise à jour ✓')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Erreur : $e')),
                  );
                }
                setState(() => _poiADeplacer = null);
              }
            },
            child: const Text('Valider'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Dialog POI unifié (carte + liste)
  // -------------------------------------------------------------------------

  /// [depuisListe] : true si le dialog est ouvert depuis l'onglet Liste
  /// (le bouton "Localiser" n'a de sens que dans ce cas, puisque depuis la
  /// carte l'anecdote est déjà localisée).
  void _ouvrirDialogPoi(PointInteret poi, {bool depuisListe = false}) {
    switch (poi.status) {
      case PoiStatus.validated:
        final estLu = _poisLusIds.contains(poi.id);
        if (estLu || _isModerator || _estMonPoiValide(poi)) {
          _afficherDialogTexte(poi, avecLocaliser: depuisListe);
        } else {
          _afficherDialogNonLu(poi);
        }
      case PoiStatus.initiated:
        _afficherDialogEdition(poi, avecLocaliser: depuisListe);
      case PoiStatus.proposed:
        if (_isModerator) {
          _afficherDialogModeration(poi, avecLocaliser: depuisListe);
        } else {
          _afficherDialogTexte(poi, avecLocaliser: depuisListe);
        }
    }
  }

void _afficherDialogTexte(PointInteret poi, {bool avecLocaliser = false}) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Anecdote'),
      // On enveloppe le texte dans un SingleChildScrollView
      content: SingleChildScrollView(
        child: Text(poi.message),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
        if (avecLocaliser)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _localiserAnecdote(poi);
            },
            child: const Text('Localiser cette anecdote'),
          ),
      ],
    ),
  );
}

/// Bascule sur l'onglet Carte et recentre la carte sur le POI donné
void _localiserAnecdote(PointInteret poi) {
  // On mémorise la cible : elle sert à la fois d'initialCenter si la carte
  // est (re)construite par TabBarView, et de cible pour le move().
  setState(() => _cibleLocalisation = poi.position);

  // Bascule immédiate (sans animation) vers l'onglet Carte
  _tabController.index = 0;

  // Si la carte est déjà construite, onMapReady ne se redéclenchera pas :
  // on la déplace donc aussi après la frame en cours.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    try {
      _mapController.move(poi.position, _zoomLocalisation);
    } catch (_) {
      // Carte pas encore prête : onMapReady prendra le relais.
    }
  });
}

/// Ouvre l'écran "Communes FaYoW". Si l'utilisateur touche une commune,
/// l'écran se ferme en la renvoyant et la carte est cadrée dessus.
Future<void> _ouvrirCommunes() async {
  final commune = await Navigator.push<CommuneFayow>(
    context,
    MaterialPageRoute(
      builder: (_) => CommunesScreen(
        pointsInteret: _pointsInteret,
        poisLusIds: _poisLusIds,
      ),
    ),
  );
  if (commune == null || !mounted) return;
  _centrerSurCommune(commune);
}

/// Cadre la carte sur l'ensemble des anecdotes validées de la commune.
/// (Le bouton n'est cliquable que sur l'onglet Carte, dont la FlutterMap est
/// maintenue en vie par _KeepAliveWrapper : on peut donc la piloter
/// directement, sans passer par _cibleLocalisation.)
void _centrerSurCommune(CommuneFayow commune) {
  if (commune.points.isEmpty) return;

  setState(() => _cibleLocalisation = null);
  _tabController.index = 0;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    try {
      if (commune.points.length == 1) {
        _mapController.move(commune.points.first, 15.0);
      } else {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(commune.points),
            padding: const EdgeInsets.all(48),
            maxZoom: 17,
          ),
        );
      }
    } catch (_) {
      // Carte pas encore prête : on ne fait rien.
    }
  });
}

/// Affiche un message explicatif quand un utilisateur non-modérateur
/// tape sur un POI validé (gris) qu'il n'a pas encore lu,
/// avec la distance qui le sépare de l'anecdote.
void _afficherDialogNonLu(PointInteret poi) {
  final metres =
      _distance.as(LengthUnit.Meter, _positionUtilisateur, poi.position);
  final distanceTexte = formaterDistance(metres);

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Anecdote non lue'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Vous n'avez pas encore lu cette anecdote. Pour le faire, rendez-vous à cet endroit.",
          ),
          const SizedBox(height: 12),
          Text(
            distanceTexte,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
}

  void _afficherDialogEdition(PointInteret poi, {bool avecLocaliser = false}) {
    final textController = TextEditingController(text: poi.message);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Modifier votre brouillon'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: textController,
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: () async {
                    final confirme =
                        await confirmerSuppressionBrouillon(context);
                    if (!confirme || !context.mounted) return;
                    Navigator.pop(context);
                    try {
                      await _poiRepository.supprimerPoi(poi.id);
                      _recharger();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Brouillon supprimé')),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Erreur : $e')),
                        );
                      }
                    }
                  },
                  child: const Text('Supprimer',
                      style: TextStyle(color: Colors.red)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Annuler'),
                ),
                if (avecLocaliser)
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.green.shade800,
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _localiserAnecdote(poi);
                    },
                    child: const Text('Localiser cette anecdote'),
                  ),
                TextButton(
                  onPressed: () async {
                    final message = textController.text.trim();
                    if (message.isEmpty) return;

                    // Confirmation avant envoi (en cas de clic par inadvertance).
                    // Sur "Non", on reste dans l'édition, texte conservé.
                    final confirme =
                        await confirmerSoumissionModeration(context, message);
                    if (!confirme || !context.mounted) return;
                    Navigator.pop(context);
                    await _poiRepository.mettreAJourPoi(
                        poi.id, {'message': message, 'status': 'proposed'});
                    _recharger();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('POI proposé à la modération !')),
                      );
                    }
                  },
                  child: const Text('Proposer',
                      style: TextStyle(color: Colors.orange)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final message = textController.text.trim();
                    if (message.isEmpty) return;
                    Navigator.pop(context);
                    await _poiRepository
                        .mettreAJourPoi(poi.id, {'message': message});
                    _recharger();
                  },
                  child: const Text('Enregistrer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _afficherDialogModeration(PointInteret poi,
      {bool avecLocaliser = false}) {
    final textController = TextEditingController(text: poi.message);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Modérer une anecdote'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: textController,
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Annuler'),
                ),
                if (avecLocaliser)
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.green.shade800,
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _localiserAnecdote(poi);
                    },
                    child: const Text('Localiser cette anecdote'),
                  ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await _afficherDialogRejetAvecMotif(poi);
                  },
                  child: const Text('Rejeter',
                      style: TextStyle(color: Colors.red)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final message = textController.text.trim();
                    if (message.isEmpty) return;
                    Navigator.pop(context);
                    await _poiRepository.mettreAJourPoi(poi.id, {
                      'message': message,
                      'status': 'validated',
                      'approved': true,
                    });
                    _recharger();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Anecdote validée !')),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Valider'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  // -------------------------------------------------------------------------
  // Rechargement
  // -------------------------------------------------------------------------

  Future<void> _recharger() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final poisValides = await _poiRepository.chargerPoisValides();
    final mesPois = await _poiRepository.chargerMesPois(uid);
    final poisLus = await _poiRepository.chargerPoisLus(uid);
    final datesLecture = await _poiRepository.chargerDatesLecture(uid);
    final tousLesPois = [...poisValides];
    for (final poi in mesPois) {
      if (!tousLesPois.any((p) => p.id == poi.id)) tousLesPois.add(poi);
    }
    if (_isModerator) {
      final proposed = await _poiRepository.chargerTousPoisProposed();
      for (final poi in proposed) {
        if (!tousLesPois.any((p) => p.id == poi.id)) tousLesPois.add(poi);
      }
    }
    if (mounted) {
      setState(() {
        _pointsInteret = tousLesPois;
        _poisLusIds = poisLus;
        _datesLecture = datesLecture;
      });
    }
  }

Future<void> _afficherDialogRejetAvecMotif(PointInteret poi) async {
  // 1. Charger les motifs depuis Firestore
  final motifs = await MailService.chargerMotifsRejet();
 
  if (motifs.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Impossible de charger les motifs')),
    );
    return;
  }
 
  // 2. État local du dialog
  final motifsSelectionnes = <String>{};
  final commentaireController = TextEditingController();
 
  // 3. Afficher le dialog de sélection
  final confirme = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setStateDialog) => AlertDialog(
        title: const Text('Motif du rejet'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Aperçu du POI
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: Text(
                  poi.message.length > 80
                      ? '${poi.message.substring(0, 80)}...'
                      : poi.message,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[700],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              const SizedBox(height: 16),
 
              // Titre motifs
              const Text(
                'Sélectionnez les motifs (plusieurs possibles) :',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
 
              // Liste des motifs avec cases à cocher
              ...motifs.map((motif) => CheckboxListTile(
                    value: motifsSelectionnes.contains(motif),
                    onChanged: (checked) {
                      setStateDialog(() {
                        if (checked == true) {
                          motifsSelectionnes.add(motif);
                        } else {
                          motifsSelectionnes.remove(motif);
                        }
                      });
                    },
                    title: Text(
                      motif,
                      style: const TextStyle(fontSize: 13),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  )),
 
              const SizedBox(height: 16),
 
              // Commentaire facultatif
              const Text(
                'Commentaire (facultatif) :',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: commentaireController,
                decoration: InputDecoration(
                  hintText: 'Précisions supplémentaires...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  contentPadding: const EdgeInsets.all(10),
                ),
                maxLines: 3,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: motifsSelectionnes.isEmpty
                ? null // Désactivé si aucun motif sélectionné
                : () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey[300],
            ),
            child: const Text('Rejeter et notifier'),
          ),
        ],
      ),
    ),
  );
 
  if (confirme != true) return;
 
  try {
    // 4. Repasser le POI en initiated
    await _poiRepository.mettreAJourPoi(poi.id, {'status': 'initiated'});
 
    // 5. Récupérer email et pseudo de l'auteur
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(poi.creatorUid)
        .get();
    final email  = userDoc.data()?['email']  as String?;
    final pseudo = userDoc.data()?['pseudo'] as String? ?? 'Utilisateur';
 
    // 6. Envoyer l'email si disponible
    if (email != null && email.isNotEmpty) {
      await MailService.envoyerEmailRejet(
        emailDestinataire:    email,
        pseudoDestinataire:   pseudo,
        messagePoiApercu:     poi.message,
        motifsSelectionnes:   motifsSelectionnes.toList(),
        commentaire:          commentaireController.text.trim(),
      );
    }
 
    // 7. Recharger les POIs
     _recharger();
      setState(() {}); // Forcer le rafraîchissement visuel
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            email != null && email.isNotEmpty
                ? 'Anecdote rejetée · $pseudo notifié par email ✓'
                : 'Anecdote rejetée (email non disponible)',
          ),
        ),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e')),
      );
    }
  }
}


  // -------------------------------------------------------------------------
  // Vue Liste
  // -------------------------------------------------------------------------

  /// En-tête de la seconde section du filtre "Proposées"
  /// (couleur neutre : la section mêle parme et vert foncé).
  Widget _buildEnteteMesValidees() {
    return Container(
      width: double.infinity,
      color: Colors.blueGrey.withOpacity(0.08),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: const Text(
        'Mes anecdotes validées',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Colors.blueGrey,
        ),
      ),
    );
  }

  Widget _buildListe() {
    final pois = _poisTries;

    if (pois.isEmpty) {
      return const Center(
        child: Text(
          'Aucune anecdote à afficher',
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    // Avec le filtre "Proposées", on insère un en-tête avant la première de
    // mes anecdotes validées (qui suivent les proposées dans le tri).
    final indexSeparation = _filtreListe == _FiltreListe.proposes
        ? pois.indexWhere(_estMonPoiValide)
        : -1;
    final avecEntete = indexSeparation != -1;
    final nbElements = pois.length + (avecEntete ? 1 : 0);

    // Marge basse : la dernière anecdote ne doit pas passer sous la barre de
    // navigation Android (le corps de l'écran s'étend derrière elle). On
    // utilise viewPadding, l'inset système brut, que Scaffold ne consomme pas,
    // avec un minimum sur Android pour les téléphones qui ne le remontent pas.
    final insetBas = MediaQuery.of(context).viewPadding.bottom;
    final margeBasse = (defaultTargetPlatform == TargetPlatform.android
            ? math.max(insetBas, 48.0)
            : insetBas) +
        16;

    final mq = MediaQuery.of(context);

    // La MediaQuery est ajustée pour que l'ascenseur (Scrollbar) s'arrête
    // au-dessus de la barre de navigation Android au lieu de passer dessous.
    return MediaQuery(
      data: mq.copyWith(
        padding: mq.padding.copyWith(bottom: margeBasse - 16),
      ),
      child: Scrollbar(
        controller: _listeController,
        thumbVisibility: true, // ascenseur toujours visible
        interactive: true, // on peut le saisir et le faire glisser
        thickness: 8,
        radius: const Radius.circular(4),
        child: ListView.separated(
      controller: _listeController,
      padding: EdgeInsets.only(top: 8, bottom: margeBasse),
      itemCount: nbElements,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (avecEntete && index == indexSeparation) {
          return _buildEnteteMesValidees();
        }
        final poi = pois[avecEntete && index > indexSeparation
            ? index - 1
            : index];
        final couleur = _getListeColor(poi);
        final statut = _getStatutLabel(poi);
        final apercu = poi.message.length > 80
            ? '${poi.message.substring(0, 80)}...'
            : poi.message;

        return ListTile(
          leading: Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: couleur,
              shape: BoxShape.circle,
            ),
          ),
          title: Text(
            apercu,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: couleur.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: couleur.withOpacity(0.5)),
                ),
                child: Text(
                  statut,
                  style: TextStyle(
                    fontSize: 11,
                    color: couleur,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${poi.position.latitude.toStringAsFixed(4)}, '
                '${poi.position.longitude.toStringAsFixed(4)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: () => _ouvrirDialogPoi(poi, depuisListe: true),
        );
      },
        ),
      ),
    );
  }

  /// Petits boutons de filtre de l'onglet Liste (affichés à droite des
  /// onglets, dans l'AppBar). Le fondu et la désactivation des taps selon
  /// l'onglet sont gérés par [_buildZoneDroite].
  Widget _buildFiltresListe() {
    Widget chip(String label, _FiltreListe filtre, [Color? couleur]) =>
        Expanded(
          child: _FiltreChip(
            label: label,
            couleur: couleur,
            selectionne: _filtreListe == filtre,
            onTap: () => setState(() => _filtreListe = filtre),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(children: [
            chip('Toutes', _FiltreListe.tout),
            const SizedBox(width: 4),
            chip('Lues', _FiltreListe.lus, Colors.green),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            chip('Proposées', _FiltreListe.proposes, Colors.blue[900]),
            const SizedBox(width: 4),
            chip('Brouillon', _FiltreListe.inities, Colors.orange),
          ]),
        ],
      ),
    );
  }

  /// Bouton d'accès à l'écran "Communes FaYoW" (visible sur l'onglet Carte).
  Widget _buildBoutonCommunes() {
    final couleur = Theme.of(context).colorScheme.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        child: SizedBox(
          height: 36,
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _ouvrirCommunes,
            icon: const Icon(Icons.location_city, size: 18),
            label: const FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('Communes FaYoW'),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: couleur,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
        ),
      ),
    );
  }

  /// Zone à droite des onglets : bouton "Communes FaYoW" sur l'onglet Carte,
  /// filtres de la liste sur l'onglet Liste, avec un fondu enchaîné qui suit
  /// le glissement entre les deux onglets.
  Widget _buildZoneDroite() {
    final animation = _tabController.animation!;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final v = animation.value.clamp(0.0, 1.0); // 0 = Carte, 1 = Liste
        return Stack(
          fit: StackFit.expand,
          children: [
            Opacity(
              opacity: 1 - v,
              child: IgnorePointer(
                ignoring: v > 0.5,
                child: _buildBoutonCommunes(),
              ),
            ),
            Opacity(
              opacity: v,
              child: IgnorePointer(
                ignoring: v < 0.5,
                child: _buildFiltresListe(),
              ),
            ),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Vue Carte
  // -------------------------------------------------------------------------

  Widget _buildCarte() {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _cibleLocalisation ?? widget.positionInitiale,
            initialZoom:
                _cibleLocalisation != null ? _zoomLocalisation : 16.0,
            onMapReady: () {
              // Carte (re)construite : on applique la cible si elle existe
              final cible = _cibleLocalisation;
              if (cible != null) {
                _mapController.move(cible, _zoomLocalisation);
              }
              _zoomCarte.value =
                  (_mapController.camera.zoom * 4).round() / 4;
            },
            // Zoom arrondi au quart de niveau : la couche des cercles n'est
            // reconstruite que lorsque ce zoom arrondi change.
            onPositionChanged: (position, hasGesture) {
              final zoom = position.zoom;
              if (zoom == null) return;
              _zoomCarte.value = (zoom * 4).round() / 4;
            },
            onTap: (tapPosition, latLng) => _onCarteTappee(latLng),
            onLongPress: (tapPosition, latLng) => _onCarteLongPress(latLng),
          ),
          children: [
ListenableBuilder(
  listenable: SettingsService.instance,
  builder: (context, _) => TileLayer(
    key: ValueKey(SettingsService.instance.mapStyle),
    urlTemplate: SettingsService.instance.mapStyle.urlTemplate('cb1_2h5p_1_cd000744af8ad5c0615a5ea8'),
    subdomains: const ['a', 'b', 'c', 'd'],
    userAgentPackageName: 'com.example.fayow',
  ),
),
            //TileLayer(
              //urlTemplate:
                //  'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png?key=cb1_2h5p_1_cd000744af8ad5c0615a5ea8',
              //subdomains: const ['a', 'b', 'c', 'd'],
              //userAgentPackageName: 'com.example.fayow',
            //),
            ValueListenableBuilder<double>(
              valueListenable: _zoomCarte,
              builder: (context, zoom, _) =>
                  CircleLayer(circles: _buildCercles(zoom)),
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: _positionUtilisateur,
                  width: 48,
                  height: 48,
                  child: ValueListenableBuilder<double>(
                    valueListenable: _cap,
                    builder: (_, cap, __) => DirectionMarker(capDegres: cap),
                  ),
                ),
              ],
            ),
          ],
        ),

        MapCompassButton(mapController: _mapController),

        MapRecenterButton(
          mapController: _mapController,
          userPosition: _positionUtilisateur,
          onRecenter: _recentrerSurUtilisateur,
          // Remonté pour rester au-dessus de la barre de navigation Android
          margin: const EdgeInsets.only(bottom: 80, right: 12),
        ),

        // LÉGENDE : bouton « i » (en bas à gauche, au-dessus de la barre Android)
        MapLegendeButton(entrees: _entreesLegende),

        // Bannière orange en mode sélection de position
        if (_modeSelectionPosition)
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.95),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.touch_app, color: Colors.white),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Tapez sur la carte pour choisir la nouvelle position',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _modeSelectionPosition = false;
                        _poiADeplacer = null;
                      });
                    },
                    child: const Text('Annuler',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        )),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Build principal
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
appBar: AppBar(
  title: const FittedBox(
  fit: BoxFit.scaleDown,
  alignment: Alignment.centerLeft,
  child: Text('Mes anecdotes'),
),
  //backgroundColor: Theme.of(context).colorScheme.primary,
  //foregroundColor: Theme.of(context).colorScheme.onPrimary,
  actions: [

            SizedBox(
            width: 100, // Largeur du bouton
            height: 35, // Hauteur du bouton
            child: ElevatedButton(

              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ClassementScreen()),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromRGBO(230, 131, 18, 1).withOpacity(0.85),
                foregroundColor: Colors.white,
              ),
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('Classement'),
              ),

          ),
            ),
    /*IconButton(
      icon: const Icon(Icons.leaderboard),
      tooltip: 'Classement',
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ClassementScreen()),
      ),
    ),
  */
  
  ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(72),
          child: Row(
            children: [
              // Onglets compacts, alignés à gauche
              SizedBox(
                width: 160,
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: Colors.white,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  dividerColor: Colors.transparent,
                  tabs: const [
                    Tab(
                    icon: Icon(Icons.map),
                    child: Text('Carte', textScaler: TextScaler.noScaling),
                    ),
                    Tab(
                    icon: Icon(Icons.list),
                    child: Text('Liste', textScaler: TextScaler.noScaling),
                  ),
                  ],
                ),
              ),
              // Zone à droite des onglets : bouton "Communes FaYoW" (Carte)
              // ou filtres de la liste (Liste), en fondu enchaîné
              // Hauteur fixée : le bas de l'AppBar donne une hauteur non bornée,
              // or le Stack (StackFit.expand) a besoin d'une hauteur finie.
              Expanded(
                child: SizedBox(height: 72, child: _buildZoneDroite()),
              ),
            ],
          ),
        ),
      ),
      
      body: TabBarView(
        controller: _tabController,
        children: [
          // La carte est maintenue en vie entre les bascules d'onglet :
          // sinon la FlutterMap est détruite, son client HTTP fermé, et les
          // tuiles en cours de téléchargement génèrent des
          // "ClientException: Client is already closed" dans le terminal.
          _KeepAliveWrapper(child: _buildCarte()),
          _buildListe(),
        ],
      ),
    );
  }
}

// Extension utilitaire
extension ListExtension<T> on List<T> {
  int indexOfFirst(bool Function(T) test) {
    for (var i = 0; i < length; i++) {
      if (test(this[i])) return i;
    }
    return -1;
  }
}

/// Empêche TabBarView de détruire son enfant lors d'un changement d'onglet.
/// Utilisé pour la carte, afin que la FlutterMap (et son client HTTP de
/// téléchargement des tuiles) survive aux allers-retours Carte <-> Liste.
class _KeepAliveWrapper extends StatefulWidget {
  final Widget child;
  const _KeepAliveWrapper({required this.child});

  @override
  State<_KeepAliveWrapper> createState() => _KeepAliveWrapperState();
}

class _KeepAliveWrapperState extends State<_KeepAliveWrapper>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // requis par AutomaticKeepAliveClientMixin
    return widget.child;
  }
}

/// Petit bouton de filtre. Sans [couleur] (bouton "Tout") : fond blanc quand
/// il est sélectionné. Avec [couleur] (celle des points sur la carte) : fond
/// de cette couleur, plein et cerclé de blanc quand il est sélectionné,
/// atténué sinon.
class _FiltreChip extends StatelessWidget {
  final String label;
  final Color? couleur;
  final bool selectionne;
  final VoidCallback onTap;

  const _FiltreChip({
    required this.label,
    required this.selectionne,
    required this.onTap,
    this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    final Color fond;
    final Color texte;
    if (couleur == null) {
      fond = selectionne ? Colors.white : Colors.white.withOpacity(0.18);
      texte = selectionne ? Colors.deepPurple : Colors.white;
    } else {
      fond = selectionne ? couleur! : couleur!.withOpacity(0.45);
      texte = selectionne ? Colors.white : Colors.white70;
    }

    return Material(
      color: fond,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: (couleur != null && selectionne)
            ? const BorderSide(color: Colors.white, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        onTap: onTap,
        child: SizedBox(
          height: 28,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        selectionne ? FontWeight.bold : FontWeight.normal,
                    color: texte,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}