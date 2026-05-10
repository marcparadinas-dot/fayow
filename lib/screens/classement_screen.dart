import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/score_service.dart';

class ClassementScreen extends StatefulWidget {
  const ClassementScreen({super.key});

  @override
  State<ClassementScreen> createState() => _ClassementScreenState();
}

class _ClassementScreenState extends State<ClassementScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _classement = [];
  final String _uidCourant = FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _chargerClassement();
  }

  Future<void> _chargerClassement() async {
    setState(() => _isLoading = true);
    final classement = await ScoreService.chargerClassement();
    setState(() {
      _classement = classement;
      _isLoading = false;
    });
  }

  // -------------------------------------------------------------------------
  // Données de l'utilisateur courant
  // -------------------------------------------------------------------------

  Map<String, dynamic>? get _monProfil {
    try {
      return _classement.firstWhere((u) => u['uid'] == _uidCourant);
    } catch (_) {
      return null;
    }
  }

  int get _maPosition {
    final index = _classement.indexWhere((u) => u['uid'] == _uidCourant);
    return index == -1 ? 0 : index + 1;
  }

  // -------------------------------------------------------------------------
  // Dialog info mode de calcul
  // -------------------------------------------------------------------------

  void _afficherInfoCalcul() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mode de calcul'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildInfoLigne(
              Icons.check_circle, Colors.green,
              'Anecdote lue', '1 point',
            ),
            const SizedBox(height: 12),
            _buildInfoLigne(
              Icons.edit, Colors.orange,
              'Anecdote initiée (brouillon)', '2 points',
            ),
            const SizedBox(height: 12),
            _buildInfoLigne(
              Icons.hourglass_empty, Colors.grey,
              'Anecdote proposée', '5 points',
            ),
            const SizedBox(height: 12),
            _buildInfoLigne(
              Icons.verified, Colors.deepPurple,
              'Anecdote validée', '10 points',
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

  Widget _buildInfoLigne(
      IconData icon, Color color, String label, String points) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Text(
          points,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: color,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Médaille selon la position
  // -------------------------------------------------------------------------

  Widget _buildMedaille(int position) {
    if (position == 1) {
      return const Text('🥇', style: TextStyle(fontSize: 20));
    } else if (position == 2) {
      return const Text('🥈', style: TextStyle(fontSize: 20));
    } else if (position == 3) {
      return const Text('🥉', style: TextStyle(fontSize: 20));
    } else {
      return Text(
        '$position',
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.grey,
        ),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final monProfil = _monProfil;
    final maPosition = _maPosition;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Classement'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Mode de calcul',
            onPressed: _afficherInfoCalcul,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _chargerClassement,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // En-tête : position de l'utilisateur courant
                if (monProfil != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Text(
                          monProfil['pseudo'] ?? 'Vous',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Classé $maPosition${maPosition == 1 ? 'er' : 'ème'} '
                          'sur ${_classement.length} '
                          '· ${monProfil['total']} points',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.9),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Liste du classement
                Expanded(
                  child: _classement.isEmpty
                      ? const Center(
                          child: Text(
                            'Aucun utilisateur dans le classement',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _classement.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final user = _classement[index];
                            final position = index + 1;
                            final estMoi = user['uid'] == _uidCourant;

                            return Container(
                              color: estMoi
                                  ? Colors.deepPurple.withOpacity(0.08)
                                  : null,
                              child: ListTile(
                                leading: SizedBox(
                                  width: 36,
                                  child: Center(
                                    child: _buildMedaille(position),
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Text(
                                      user['pseudo'] ?? 'Anonyme',
                                      style: TextStyle(
                                        fontWeight: estMoi
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: estMoi
                                            ? Colors.deepPurple
                                            : null,
                                      ),
                                    ),
                                    if (estMoi) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.deepPurple,
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'Vous',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: Text(
                                  '${user['poisLus']} lu · '
                                  '${user['poisInitiated']} initié · '
                                  '${user['poisProposed']} proposé · '
                                  '${user['poisValidated']} validé',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: Text(
                                  '${user['total']} pts',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                    color: estMoi
                                        ? Colors.deepPurple
                                        : Colors.black87,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}