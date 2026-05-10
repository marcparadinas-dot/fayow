import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'map_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController    = TextEditingController();
  final _passwordController = TextEditingController();
  final _pseudoController   = TextEditingController();

  bool _isInscription = false; // false = Connexion, true = Inscription
  bool _isLoading     = false;
  String _errorMessage = '';

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _pseudoController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Connexion
  // -------------------------------------------------------------------------

  Future<void> _signIn() async {
    setState(() { _isLoading = true; _errorMessage = ''; });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email:    _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MapScreen()),
        );
      }
    } on FirebaseAuthException catch (e) {
      setState(() { _errorMessage = _traduireErreur(e.code); });
    } catch (e) {
      setState(() { _errorMessage = e.toString(); });
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  // -------------------------------------------------------------------------
  // Inscription
  // -------------------------------------------------------------------------

Future<void> _signUp() async {
  final pseudo = _pseudoController.text.trim();
  if (pseudo.isEmpty) {
    setState(() { _errorMessage = 'Veuillez choisir un pseudo.'; });
    return;
  }
  if (pseudo.length < 2) {
    setState(() { _errorMessage = 'Le pseudo doit contenir au moins 2 caractères.'; });
    return;
  }

  setState(() { _isLoading = true; _errorMessage = ''; });

  try {
    // Vérifier si le pseudo est déjà pris (insensible à la casse)
    final pseudoKey = pseudo.toLowerCase();
    final pseudoDoc = await FirebaseFirestore.instance
        .collection('pseudos')
        .doc(pseudoKey)
        .get();

    if (pseudoDoc.exists) {
      setState(() {
        _errorMessage = 'Ce pseudo est déjà utilisé. Choisissez-en un autre.';
        _isLoading = false;
      });
      return;
    }

    // Créer le compte Firebase Auth
    final credential = await FirebaseAuth.instance
        .createUserWithEmailAndPassword(
      email:    _emailController.text.trim(),
      password: _passwordController.text.trim(),
    );

    final uid = credential.user?.uid;
    if (uid != null) {
      // Enregistrer le pseudo dans users/{uid}
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set({'pseudo': pseudo}, SetOptions(merge: true));

      // Réserver le pseudo dans la collection pseudos
      await FirebaseFirestore.instance
          .collection('pseudos')
          .doc(pseudoKey)
          .set({'uid': uid, 'pseudo': pseudo});
    }

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MapScreen()),
      );
    }
  } on FirebaseAuthException catch (e) {
    setState(() { _errorMessage = _traduireErreur(e.code); });
  } catch (e) {
    setState(() { _errorMessage = e.toString(); });
  } finally {
    setState(() { _isLoading = false; });
  }
}

  // -------------------------------------------------------------------------
  // Traduction des erreurs Firebase
  // -------------------------------------------------------------------------

  String _traduireErreur(String code) {
    switch (code) {
      case 'user-not-found':
        return 'Aucun compte trouvé avec cet email.';
      case 'wrong-password':
        return 'Mot de passe incorrect.';
      case 'invalid-email':
        return 'Adresse email invalide.';
      case 'email-already-in-use':
        return 'Cet email est déjà utilisé.';
      case 'weak-password':
        return 'Le mot de passe doit contenir au moins 6 caractères.';
      case 'too-many-requests':
        return 'Trop de tentatives. Réessayez plus tard.';
      case 'invalid-credential':
        return 'Email ou mot de passe incorrect.';
      default:
        return 'Erreur : $code';
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Titre
                Text(
                  'FaYoW',
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    color: Colors.deepPurple[700],
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Points d\'intérêt géolocalisés',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 40),

                // Carte du formulaire
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [

                        // Bascule Connexion / Inscription
                        Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  _isInscription = false;
                                  _errorMessage = '';
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  decoration: BoxDecoration(
                                    color: !_isInscription
                                        ? Colors.deepPurple
                                        : Colors.grey[200],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Connexion',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: !_isInscription
                                          ? Colors.white
                                          : Colors.grey[600],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  _isInscription = true;
                                  _errorMessage = '';
                                }),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  decoration: BoxDecoration(
                                    color: _isInscription
                                        ? Colors.deepPurple
                                        : Colors.grey[200],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Inscription',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: _isInscription
                                          ? Colors.white
                                          : Colors.grey[600],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // Champ pseudo (inscription uniquement)
                        if (_isInscription) ...[
                          TextField(
                            controller: _pseudoController,
                            decoration: InputDecoration(
                              labelText: 'Pseudo',
                              hintText: 'Votre nom d\'affichage',
                              prefixIcon: const Icon(Icons.person_outline),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 16),
                        ],

                        // Champ email
                        TextField(
                          controller: _emailController,
                          decoration: InputDecoration(
                            labelText: 'Email',
                            prefixIcon: const Icon(Icons.email_outlined),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 16),

                        // Champ mot de passe
                        TextField(
                          controller: _passwordController,
                          decoration: InputDecoration(
                            labelText: 'Mot de passe',
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          obscureText: true,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) =>
                              _isInscription ? _signUp() : _signIn(),
                        ),
                        const SizedBox(height: 16),

                        // Message d'erreur
                        if (_errorMessage.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.red[50],
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.red[200]!),
                            ),
                            child: Text(
                              _errorMessage,
                              style: TextStyle(
                                color: Colors.red[700],
                                fontSize: 13,
                              ),
                            ),
                          ),
                        if (_errorMessage.isNotEmpty) const SizedBox(height: 16),

                        // Bouton principal
                        if (_isLoading)
                          const Center(child: CircularProgressIndicator())
                        else
                          ElevatedButton(
                            onPressed: _isInscription ? _signUp : _signIn,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.deepPurple,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: Text(
                              _isInscription ? 'Créer mon compte' : 'Se connecter',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}