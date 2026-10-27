import 'package:flutter/material.dart';

/// Demande confirmation avant la suppression d'un brouillon
Future<bool> confirmerSuppressionBrouillon(BuildContext context) async {
  final resultat = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer ce brouillon ?'),
      content: const Text('Cette action est définitive.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Non'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Supprimer',
              style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );
  return resultat ?? false;
}
/// Demande confirmation avant l'envoi d'une anecdote à la modération, en
/// rappelant le texte concerné. Renvoie true uniquement si l'utilisateur
/// répond "Oui" (fermer la fenêtre ou répondre "Non" renvoie false).
Future<bool> confirmerSoumissionModeration(
  BuildContext context,
  String message,
) async {
  final reponse = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Soumettre à la modération ?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Voulez-vous vraiment soumettre ce texte à la modération ?',
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Text(
                message,
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Non'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Oui'),
        ),
      ],
    ),
  );
  return reponse == true;
}