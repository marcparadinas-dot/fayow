import 'package:latlong2/latlong.dart';

enum PoiStatus { initiated, proposed, validated }

class PointInteret {
  final String id;
  final LatLng position;
  final String message;
  final PoiStatus status;
  final String creatorUid;

  /// Localisation administrative du POI. Ces champs sont renseignés côté
  /// serveur (Cloud Function `enrichirCommunePoi`, via Nominatim) : ils sont
  /// absents des anciens POIs tant que le rattrapage n'a pas été lancé.
  final String? commune;
  final String? departement;
  final String? region;
  final String? pays;

  PointInteret({
    required this.id,
    required this.position,
    required this.message,
    required this.status,
    required this.creatorUid,
    this.commune,
    this.departement,
    this.region,
    this.pays,
  });

  factory PointInteret.fromFirestore(String id, Map<String, dynamic> data) {
    return PointInteret(
      id: id,
      position: LatLng(
        (data['lat'] as num).toDouble(),
        (data['lng'] as num).toDouble(),
      ),
      message: data['message'] ?? '',
      status: PoiStatus.values.firstWhere(
        (e) => e.name == (data['status'] ?? 'initiated'),
        orElse: () => PoiStatus.initiated,
      ),
      creatorUid: data['creatorUid'] ?? '',
      commune: data['commune']?.toString(),
      departement: data['departement']?.toString(),
      region: data['region']?.toString(),
      pays: data['pays']?.toString(),
    );
  }

  PointInteret copyWith({LatLng? position}) {
    return PointInteret(
      id: id,
      position: position ?? this.position,
      message: message,
      status: status,
      creatorUid: creatorUid,
      commune: commune,
      departement: departement,
      region: region,
      pays: pays,
    );
  }
}