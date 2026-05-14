import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_screen.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'classement_screen.dart';

class ProfilScreen extends StatefulWidget {
  const ProfilScreen({super.key});

  @override
  State<ProfilScreen> createState() => _ProfilScreenState();
}

class _ProfilScreenState extends State<ProfilScreen> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  bool _isLoading = true;

  // Données profil
  String _pseudo = '';
  String _email = '';

  // Stats
  int _poisLus = 0;
  int _poisValides = 0;
  int _poisProposed = 0;
  int _poisInitiated = 0;
  double _pourcentageLus = 0;

  @override
  void initState() {
    super.initState();
    _chargerProfil();
  }

  // -------------------------------------------------------------------------
  // Chargement du profil et des stats
  // -------------------------------------------------------------------------

  Future<void> _chargerProfil() async {
    setState(() => _isLoading = true);
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    try {
      // Profil utilisateur
      final userDoc = await _db.collection('users').doc(uid).get();
      _pseudo = userDoc.data()?['pseudo'] ?? '';
      _email  = _auth.currentUser?.email ?? '';

      // Nombre de POIs lus
      final poisLusSnap = await _db
          .collection('users')
          .doc(uid)
          .collection('readPois')
          .get();
      _poisLus = poisLusSnap.docs.length;

      // Mes POIs par statut
      final mesPoisSnap = await _db
          .collection('pois')
          .where('creatorUid', isEqualTo: uid)
          .get();

      _poisValides  = mesPoisSnap.docs
          .where((d) => d.data()['status'] == 'validated')
          .length;
      _poisProposed = mesPoisSnap.docs
          .where((d) => d.data()['status'] == 'proposed')
          .length;
      _poisInitiated = mesPoisSnap.docs
          .where((d) => d.data()['status'] == 'initiated')
          .length;

      // Pourcentage de POIs validés lus / total validés dans la base
      final totalValidesSnap = await _db
          .collection('pois')
          .where('status', isEqualTo: 'validated')
          .get();
      final totalValides = totalValidesSnap.docs.length;
      _pourcentageLus = totalValides > 0
          ? (_poisLus / totalValides * 100).clamp(0, 100)
          : 0;

      setState(() => _isLoading = false);
    } catch (e) {
      print('Erreur chargement profil : $e');
      setState(() => _isLoading = false);
    }
  }

  // -------------------------------------------------------------------------
  // Changement de pseudo
  // -------------------------------------------------------------------------

  Future<void> _changerPseudo() async {
    final controller = TextEditingController(text: _pseudo);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Changer de pseudo'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Nouveau pseudo'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () async {
              final nouveauPseudo = controller.text.trim();
              if (nouveauPseudo.isEmpty || nouveauPseudo.length < 2) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Le pseudo doit contenir au moins 2 caractères')),
                );
                return;
              }
              if (nouveauPseudo == _pseudo) {
                Navigator.pop(context);
                return;
              }
              Navigator.pop(context);
              await _sauvegarderPseudo(nouveauPseudo);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  Future<void> _sauvegarderPseudo(String nouveauPseudo) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    setState(() => _isLoading = true);

    try {
      final pseudoKey = nouveauPseudo.toLowerCase();

      // Vérifier unicité
      final existing = await _db.collection('pseudos').doc(pseudoKey).get();
      if (existing.exists && existing.data()?['uid'] != uid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ce pseudo est déjà utilisé')),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      // Supprimer l'ancien pseudo de la collection pseudos
      final ancienPseudoKey = _pseudo.toLowerCase();
      if (ancienPseudoKey.isNotEmpty) {
        await _db.collection('pseudos').doc(ancienPseudoKey).delete();
      }

      // Enregistrer le nouveau pseudo
      await _db.collection('users').doc(uid).update({'pseudo': nouveauPseudo});
      await _db.collection('pseudos').doc(pseudoKey).set({
        'uid': uid,
        'pseudo': nouveauPseudo,
      });

      setState(() {
        _pseudo = nouveauPseudo;
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pseudo mis à jour ✓')),
        );
      }
    } catch (e) {
      print('Erreur changement pseudo : $e');
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e')),
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // Changement d'email
  // -------------------------------------------------------------------------

  Future<void> _changerEmail() async {
    final controller = TextEditingController(text: _email);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Changer d\'email'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Nouvel email'),
          keyboardType: TextInputType.emailAddress,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () async {
              final nouvelEmail = controller.text.trim();
              if (nouvelEmail.isEmpty || !nouvelEmail.contains('@')) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Email invalide')),
                );
                return;
              }
              if (nouvelEmail == _email) {
                Navigator.pop(context);
                return;
              }
              Navigator.pop(context);
              await _sauvegarderEmail(nouvelEmail);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

Future<void> _sauvegarderEmail(String nouvelEmail) async {
  setState(() => _isLoading = true);
  try {
    final user = _auth.currentUser;
    if (user == null) return;

    // Forcer le rafraîchissement du token avant l'appel
    await user.getIdToken(true);

    final uid = user.uid;
    final functionsInstance = FirebaseFunctions.instanceFor(region: 'us-central1');
    final callable = functionsInstance.httpsCallable('updateUserEmail');
    
    await callable.call({
      'targetUid': uid,
      'newEmail': nouvelEmail,
    });
final result = await callable.call({
  'targetUid': uid,
  'newEmail': nouvelEmail,
});

// Mettre à jour l'email dans Firestore pour la cohérence
await FirebaseFirestore.instance
    .collection('users')
    .doc(uid)
    .update({'email': nouvelEmail});

setState(() {
  _email = nouvelEmail;
  _isLoading = false;
});

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Email mis à jour ✓')),
      );
    }
  } on FirebaseFunctionsException catch (e) {
    setState(() => _isLoading = false);
    String message;
    switch (e.code) {
      case 'already-exists':
        message = 'Cet email est déjà utilisé.';
        break;
      case 'not-found':
        message = 'Utilisateur introuvable.';
        break;
      case 'unauthenticated':
        message = 'Session expirée, reconnectez-vous.';
        break;
      default:
        message = 'Erreur : ${e.message}';
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  } catch (e) {
    setState(() => _isLoading = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur : $e')),
      );
    }
  }
}

  // -------------------------------------------------------------------------
  // Déconnexion
  // -------------------------------------------------------------------------

  Future<void> _signOut() async {
    await _auth.signOut();
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const AuthScreen()),
        (route) => false,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mon profil'),
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
      ),
      
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Avatar + pseudo
                  Center(
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 40,
                          backgroundColor: Colors.deepPurple[100],
                          child: Text(
                            _pseudo.isNotEmpty
                                ? _pseudo[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: Colors.deepPurple[700],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _pseudo.isNotEmpty ? _pseudo : 'Sans pseudo',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Infos modifiables
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.person, color: Colors.deepPurple),
                          title: const Text('Pseudo'),
                          subtitle: Text(_pseudo.isNotEmpty ? _pseudo : 'Non défini'),
                          trailing: IconButton(
                            icon: const Icon(Icons.edit, size: 20),
                            onPressed: _changerPseudo,
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.email, color: Colors.deepPurple),
                          title: const Text('Email'),
                          subtitle: Text(_email),
                          trailing: IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          onPressed: _changerEmail,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Statistiques
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Mes statistiques',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Barre de progression
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('POIs lus'),
                              Text(
                                '${_pourcentageLus.toStringAsFixed(1)} %',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: _pourcentageLus / 100,
                              minHeight: 10,
                              backgroundColor: Colors.grey[200],
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                  Colors.green),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Stats détaillées
                          _buildStatRow(
                            Icons.check_circle,
                            Colors.green,
                            'Anecdotes lues',
                            _poisLus,
                          ),
                          const SizedBox(height: 8),
                          _buildStatRow(
                            Icons.add_location_alt,
                            Colors.orange,
                            'Brouillons (initiés)',
                            _poisInitiated,
                          ),
                          const SizedBox(height: 8),
                          _buildStatRow(
                            Icons.hourglass_empty,
                            Colors.grey,
                            'En attente de modération',
                            _poisProposed,
                          ),
                          const SizedBox(height: 8),
                          _buildStatRow(
                            Icons.verified,
                            Colors.deepPurple,
                            'Validés par la modération',
                            _poisValides,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Bouton déconnexion
                  ElevatedButton.icon(
                    onPressed: _signOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('Déconnexion'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildStatRow(
      IconData icon, Color color, String label, int valeur) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
        Text(
          valeur.toString(),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: color,
            fontSize: 16,
          ),
        ),
      ],
    );
  }
}