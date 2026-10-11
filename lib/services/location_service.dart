import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class LocationService {

  /// À appeler après connexion, avant d'ouvrir MapScreen (et depuis MapScreen
  /// quand l'utilisateur appuie sur « Autoriser la localisation »).
  ///
  /// Séquence :
  ///   1. permission « pendant l'utilisation » (obligatoire) ;
  ///   2. en cas de refus : explication, puis nouvelle demande ou ouverture
  ///      des réglages si le système ne redemande plus ;
  ///   3. seulement si 1 est accordée : permission « toujours » (Android,
  ///      facultative), avec son écran d'explication.
  ///
  /// Retourne true si la localisation « pendant l'utilisation » est accordée,
  /// false si l'utilisateur y renonce ou est parti dans les réglages. L'appelant
  /// doit alors afficher un état explicite : l'appli ne peut pas fonctionner
  /// sans position.
  static Future<bool> demanderPermissions(BuildContext context) async {
    // 1. Permission « en cours d'utilisation » (obligatoire avant « toujours »)
    var statut = await Permission.location.status;
    if (!statut.isGranted) {
      statut = await Permission.location.request();
    }

    // 2. Refus : on n'enchaîne PAS sur la demande « toujours » (Android l'ignore
    //    tant que la première n'est pas accordée). On explique, puis on
    //    redemande, ou on envoie vers les réglages si le système ne redemande plus.
    var tentatives = 0;
    while (!statut.isGranted) {
      if (!context.mounted) return false;
      tentatives++;
      final definitif = statut.isPermanentlyDenied || tentatives > 2;
      final continuer = await _expliquerRefus(context, definitif: definitif);
      if (!continuer) return false;
      if (definitif) {
        // Seul l'écran de réglages permet de changer d'avis. On ne peut pas
        // attendre le retour de l'utilisateur ici : MapScreen revérifie la
        // permission quand l'appli repasse au premier plan.
        await openAppSettings();
        return false;
      }
      statut = await Permission.location.request();
    }

    // 3. Permission « toujours » (Android uniquement) — facultative
    if (Platform.isAndroid && context.mounted) {
      final arrierePlan = await Permission.locationAlways.status;
      if (!arrierePlan.isGranted && context.mounted) {
        final accepter = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text("Localisation en arrière-plan"),
            content: const Text(
              "FaYoW souhaite accéder à votre position, y compris lorsque "
              "l'application est fermée ou en arrière-plan, afin de vous "
              "notifier des points d'intérêt géolocalisés à proximité dès "
              "qu'ils apparaissent sur votre trajet.\n\n"
              "Cette donnée n'est jamais partagée avec des tiers ni utilisée "
              "à d'autres fins.\n\n"
              "Si vous acceptez, l'écran suivant vous demandera de sélectionner "
              "'Toujours autoriser'."
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("Refuser"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("Accepter"),
              ),
            ],
          ),
        );
        // La demande est attendue ICI (et non dans le bouton du dialogue) :
        // sinon MapScreen s'ouvre pendant que la demande système est encore en
        // cours, et deux demandes simultanées peuvent bloquer l'écran.
        if (accepter == true) {
          await Permission.locationAlways.request();
        }
      }
    }

    return true;
  }

  /// Chemin à suivre dans les réglages du téléphone. Écrit en toutes lettres
  /// car l'ouverture des réglages n'arrive pas toujours sur la page de l'appli
  /// (notamment sur iOS tant que l'appli n'y a pas d'entrée).
  static String get _cheminReglages => Platform.isIOS
      ? "Pour l'activer :\n"
        "1. Ouvrez Réglages\n"
        "2. Touchez FaYoW (en bas de la liste)\n"
        "3. Touchez Position, puis « Lorsque l'app est active »\n\n"
        "Si FaYoW n'apparaît pas, allez dans Réglages › Confidentialité et "
        "sécurité › Services de localisation › FaYoW."
      : "Pour l'activer : Paramètres › Applications › FaYoW › Autorisations › "
        "Position, puis « Autoriser uniquement lorsque l'appli est utilisée ».";

  /// Explique à l'utilisateur que le refus empêche l'appli de fonctionner.
  /// Retourne true s'il veut réessayer / ouvrir les réglages, false s'il renonce.
  static Future<bool> _expliquerRefus(
    BuildContext context, {
    required bool definitif,
  }) async {
    final choix = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("Localisation nécessaire"),
        content: Text(
          definitif
              ? "FaYoW a besoin de votre position pour vous signaler les "
                "anecdotes autour de vous : sans elle, l'application ne peut "
                "pas fonctionner.\n\n"
                "L'autorisation a été refusée et le système ne la redemandera "
                "plus.\n\n" + _cheminReglages
              : "FaYoW a besoin de votre position pour vous signaler les "
                "anecdotes autour de vous : sans elle, l'application ne peut "
                "pas fonctionner.\n\n"
                "Vous n'avez pas accordé l'autorisation. Souhaitez-vous "
                "réessayer ?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Plus tard"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(definitif ? "Ouvrir les réglages" : "Réessayer"),
          ),
        ],
      ),
    );
    return choix == true;
  }
}