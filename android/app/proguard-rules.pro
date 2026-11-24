# Flutter et la plupart des plugins (Firebase, geolocator, flutter_tts, permission_handler...)
# embarquent leurs propres règles. On n'ajoute que le strict nécessaire.

# Play Core (deferred components), référencé par le moteur Flutter mais absent de l'appli
-dontwarn com.google.android.play.core.**

# Conserve les numéros de ligne dans les stack traces (utile avec mapping.txt dans la Play Console)
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile