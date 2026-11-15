import 'package:flutter/material.dart';

/// Une ligne de la légende : pastille (même rendu que les cercles de la
/// carte : fond translucide + bordure), titre et explication.
class LegendeEntree {
  final Color couleurFond;
  final Color couleurBordure;
  final String titre;
  final String? description;

  const LegendeEntree({
    required this.couleurFond,
    required this.couleurBordure,
    required this.titre,
    this.description,
  });
}

/// Petit bouton « i » posé sur la carte. Au clic, ouvre une fenêtre qui
/// explique la signification des couleurs des points.
class MapLegendeButton extends StatelessWidget {
  final List<LegendeEntree> entrees;
  final String titre;
  final Alignment alignment;
  final EdgeInsets margin;

  const MapLegendeButton({
    super.key,
    required this.entrees,
    this.titre = 'Légende',
    this.alignment = Alignment.bottomLeft,
    // Remonté pour rester au-dessus de la barre de navigation Android
    this.margin = const EdgeInsets.only(bottom: 80, left: 12),
  });

  void _afficherLegende(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(titre),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entree in entrees) _LigneLegende(entree: entree),
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

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: margin,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          elevation: 3,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _afficherLegende(context),
            child: const Tooltip(
              message: 'Légende des couleurs',
              child: Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.info_outline, size: 24),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LigneLegende extends StatelessWidget {
  final LegendeEntree entree;
  const _LigneLegende({required this.entree});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: entree.couleurFond,
              border: Border.all(color: entree.couleurBordure, width: 3),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entree.titre,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (entree.description != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      entree.description!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}