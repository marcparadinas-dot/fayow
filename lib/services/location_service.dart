import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class LocationService {

  /// À appeler une fois après connexion, avant d'ouvrir MapScreen.
  static Future<void> demanderPermissions(BuildContext context) async {
    // 1. Permission "en cours d'utilisation" d'abord (obligatoire avant background)
    final locationStatus = await Permission.location.status;
    if (!locationStatus.isGranted) {
      await Permission.location.request();
    }

    // 2. Permission background (Android uniquement)
    if (Platform.isAndroid) {
      final backgroundStatus = await Permission.locationAlways.status;
      if (!backgroundStatus.isGranted && context.mounted) {
        await showDialog(
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
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Refuser"),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await Permission.locationAlways.request();
                },
                child: const Text("Accepter"),
              ),
            ],
          ),
        );
      }
    }
  }
}