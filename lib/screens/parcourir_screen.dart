import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/poi_models.dart';
import '../repository/poi_repository.dart';
import '../services/auth_service.dart';
import '../services/score_service.dart';
import 'classement_screen.dart';
import '../services/mail_service.dart';

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
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // POIs visibles (filtrés selon le profil)
  // -------------------------------------------------------------------------

  List<PointInteret> get _poisVisibles {
    return _pointsInteret.where((poi) {
      final estLu = _poisLusIds.contains(poi.id);
      return switch (poi.status) {
        PoiStatus.validated => estLu || _isModerator,
        PoiStatus.initiated => true,
        PoiStatus.proposed => true,
      };
    }).toList();
  }

  // POIs triés : validés lus, puis proposés, puis initiés
  List<PointInteret> get _poisTries {
    final liste = List<PointInteret>.from(_poisVisibles);
    liste.sort((a, b) {
      int ordreStatut(PointInteret p) {
        if (p.status == PoiStatus.validated && _poisLusIds.contains(p.id)) return 0;
        if (p.status == PoiStatus.proposed) return 1;
        if (p.status == PoiStatus.initiated) return 2;
        if (p.status == PoiStatus.validated) return 3; // validés non lus (modérateur)
        return 4;
      }
      return ordreStatut(a).compareTo(ordreStatut(b));
    });
    return liste;
  }

  // -------------------------------------------------------------------------
  // Couleurs
  // -------------------------------------------------------------------------

  Color _getCercleColor(PointInteret poi) {
    if (poi.status == PoiStatus.validated && _poisLusIds.contains(poi.id)) {
      return Colors.green.withOpacity(0.4);
    }
    if (poi.status == PoiStatus.validated && _isModerator) {
      return Colors.purple.withOpacity(0.3);
    }
    switch (poi.status) {
      case PoiStatus.initiated:
        return Colors.orange.withOpacity(0.5);
      case PoiStatus.proposed:
        return Colors.grey.withOpacity(0.5);
      case PoiStatus.validated:
        return Colors.transparent;
    }
  }

  Color _getCercleBorderColor(PointInteret poi) {
    if (poi.status == PoiStatus.validated && _poisLusIds.contains(poi.id)) {
      return Colors.green;
    }
    if (poi.status == PoiStatus.validated && _isModerator) {
      return Colors.purple;
    }
    switch (poi.status) {
      case PoiStatus.initiated:
        return Colors.orange;
      case PoiStatus.proposed:
        return Colors.grey;
      case PoiStatus.validated:
        return Colors.transparent;
    }
  }

  Color _getListeColor(PointInteret poi) {
    if (poi.status == PoiStatus.validated && _poisLusIds.contains(poi.id)) {
      return Colors.green;
    }
    if (poi.status == PoiStatus.validated) return Colors.purple;
    if (poi.status == PoiStatus.proposed) return Colors.grey;
    return Colors.orange;
  }

  String _getStatutLabel(PointInteret poi) {
    if (poi.status == PoiStatus.validated && _poisLusIds.contains(poi.id)) {
      return 'Lu';
    }
    if (poi.status == PoiStatus.validated) return 'Validé';
    if (poi.status == PoiStatus.proposed) return 'Proposé';
    return 'Brouillon';
  }

  // -------------------------------------------------------------------------
  // Construction des cercles (carte)
  // -------------------------------------------------------------------------

  List<CircleMarker> _buildCercles() {
    final cercles = <CircleMarker>[];
    for (final poi in _poisVisibles) {
      final enDeplacement = _poiADeplacer?.id == poi.id;
      cercles.add(CircleMarker(
        point: poi.position,
        radius: 20,
        useRadiusInMeter: true,
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

    const double seuilMetres = 30.0;
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
    const double seuilMetres = 30.0;
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

  void _ouvrirDialogPoi(PointInteret poi) {
    switch (poi.status) {
      case PoiStatus.validated:
        _afficherDialogTexte(poi.message);
      case PoiStatus.initiated:
        _afficherDialogEdition(poi);
      case PoiStatus.proposed:
        if (_isModerator) {
          _afficherDialogModeration(poi);
        } else {
          _afficherDialogTexte(poi.message);
        }
    }
  }

  void _afficherDialogTexte(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Anecdote'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  void _afficherDialogEdition(PointInteret poi) {
    final textController = TextEditingController(text: poi.message);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier votre brouillon'),
        content: TextField(controller: textController, maxLines: 4),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () async {
              final message = textController.text.trim();
              if (message.isEmpty) return;
              Navigator.pop(context);
              await _poiRepository.mettreAJourPoi(
                  poi.id, {'message': message, 'status': 'proposed'});
              _recharger();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('POI proposé à la modération !')),
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
              await _poiRepository.mettreAJourPoi(poi.id, {'message': message});
              _recharger();
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  void _afficherDialogModeration(PointInteret poi) {
    final textController = TextEditingController(text: poi.message);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modérer une anecdote'),
        content: TextField(controller: textController, maxLines: 4),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _afficherDialogRejetAvecMotif(poi);
            },
            child: const Text('Rejeter', style: TextStyle(color: Colors.red)),
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

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: pois.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final poi = pois[index];
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
          onTap: () => _ouvrirDialogPoi(poi),
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
            initialCenter: widget.positionInitiale,
            initialZoom: 16.0,
            onTap: (tapPosition, latLng) => _onCarteTappee(latLng),
            onLongPress: (tapPosition, latLng) => _onCarteLongPress(latLng),
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              userAgentPackageName: 'com.example.fayow',
            ),
            CircleLayer(circles: _buildCercles()),
          ],
        ),

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
  title: const Text('Mes anecdotes'),
  backgroundColor: Colors.deepPurple,
  foregroundColor: Colors.white,
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
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.map), text: 'Carte'),
            Tab(icon: Icon(Icons.list), text: 'Liste'),
          ],
        ),
      ),
      
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildCarte(),
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