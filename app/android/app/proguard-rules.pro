# ---- ML Kit barcode scanning (mobile_scanner: QR-address scan in Send) ----
# ML Kit discovers its components by reflection. Release builds here are R8-minified
# (this Flutter forces isMinifyEnabled=true), which stripped these classes' constructors —
# breaking the scanner with a black camera + "NoSuchMethodException: <ComponentRegistrar>.<init> []"
# and a NullPointerException in the plugin. Keep them so R8 leaves them intact.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-dontwarn com.google.mlkit.**

# ---- mobile_scanner plugin ----
-keep class dev.steenbakker.mobile_scanner.** { *; }
