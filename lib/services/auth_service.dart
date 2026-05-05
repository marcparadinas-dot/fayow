import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  // Liste des emails modérateurs — identique aux règles Firestore
  static const List<String> _moderateurEmails = [
    'marc.paradinas@gmail.com',
    'marc.paradinas@wanadoo.fr',
  ];

  static bool get isModerator {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    return _moderateurEmails.contains(user.email?.toLowerCase());
  }
}