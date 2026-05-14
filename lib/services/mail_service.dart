import 'package:cloud_firestore/cloud_firestore.dart';

class MailService {
  static final _db = FirebaseFirestore.instance;

  // -------------------------------------------------------------------------
  // Chargement des motifs de rejet depuis Firestore
  // -------------------------------------------------------------------------

  static Future<List<String>> chargerMotifsRejet() async {
    try {
      final doc = await _db.collection('config').doc('moderation').get();
      final data = doc.data();
      if (data == null) return [];
      final motifs = data['motifsRejet'] as List<dynamic>? ?? [];
      return motifs.map((m) => m.toString()).toList();
    } catch (e) {
      print('Erreur chargement motifs : $e');
      return [];
    }
  }

  // -------------------------------------------------------------------------
  // Envoi email de rejet
  // -------------------------------------------------------------------------

  static Future<void> envoyerEmailRejet({
    required String emailDestinataire,
    required String pseudoDestinataire,
    required String messagePoiApercu,
    required List<String> motifsSelectionnes,
    String? commentaire,
  }) async {
    try {
      // Construction de la liste des motifs en HTML
      final motifsHtml = motifsSelectionnes
          .map((m) => '<li>$m</li>')
          .join('\n');

      // Aperçu du POI
      final apercu = messagePoiApercu.length > 100
          ? '${messagePoiApercu.substring(0, 100)}...'
          : messagePoiApercu;

      // Bloc commentaire facultatif
      final commentaireHtml = (commentaire != null && commentaire.isNotEmpty)
          ? '''
<p><strong>Commentaire du modérateur :</strong><br>
$commentaire</p>
'''
          : '';

      final html = '''
<p>Bonjour $pseudoDestinataire,</p>

<p>Vous avez proposé une anecdote sur FaYoW et nous vous en remercions :</p>

<blockquote style="border-left: 3px solid #ccc; padding-left: 12px; color: #555;">
  <em>$apercu</em>
</blockquote>

<p>Malheureusement, elle n'a pas été retenue par la modération pour les motifs suivants :</p>

<ul>
$motifsHtml
</ul>

$commentaireHtml

<p>Votre anecdote est repassée en brouillon. Vous pouvez la modifier, 
la repositionner et la proposer à nouveau depuis l'application FaYoW.</p>

<p>Cordialement,<br>
<strong>L'équipe FaYoW</strong></p>
''';

      await _db.collection('mail').add({
        'to': emailDestinataire,
        'message': {
          'subject': 'FaYoW - Votre anecdote n\'a pas été retenue',
          'html': html,
        },
      });

      print('MailService : email de rejet envoyé à $emailDestinataire');
    } catch (e) {
      print('Erreur envoi email rejet : $e');
      rethrow;
    }
  }
}