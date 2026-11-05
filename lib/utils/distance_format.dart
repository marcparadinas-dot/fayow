/// Formate une distance (en mètres) en phrase pour l'utilisateur :
/// « Il se trouve à 350 mètres de vous. » ou
/// « Il se trouve à 2,4 kilomètres de vous. »
String formaterDistance(double metres) {
  final m = metres.round();
  if (m < 1000) {
    return 'Il se trouve à $m ${m > 1 ? 'mètres' : 'mètre'} de vous.';
  }
  final km = metres / 1000;
  final texte = km < 10
      ? km.toStringAsFixed(1).replaceAll('.', ',')
      : km.round().toString();
  return 'Il se trouve à $texte kilomètres de vous.';
}