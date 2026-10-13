# R8 keep rules for the release build.
# The SSH stack finds algorithms, providers and factories by name and through reflection, so it is kept whole rather than
# shrunk: sshj (key exchange, ciphers, MACs, host-key and auth factories), BouncyCastle (installed as a security provider) and
# slf4j (sshj logs through it; the no-op binding is bundled).
-keep class net.schmizz.** { *; }
-keep class com.hierynomus.** { *; }
-keep class org.bouncycastle.** { *; }
-keep class org.slf4j.** { *; }
-dontwarn net.schmizz.**
-dontwarn com.hierynomus.**
-dontwarn org.bouncycastle.**
-dontwarn org.slf4j.**
-dontwarn javax.naming.**
-dontwarn org.ietf.jgss.**
-dontwarn javax.security.auth.**
-dontwarn com.jcraft.jzlib.**
-dontwarn com.sun.jna.**

# The terminal emulator (ConnectBot termlib) has native-facing and callback classes.
-keep class org.connectbot.** { *; }
-dontwarn org.connectbot.**

# kotlinx.serialization: the plugin's own consumer rules cover generated serializers; keep the annotations and names it reads.
-keepattributes *Annotation*, InnerClasses, Signature, RuntimeVisibleAnnotations
-keep,includedescriptorclasses class com.bgallagher.rackoon.**$$serializer { *; }
-keepclassmembers class com.bgallagher.rackoon.** { *** Companion; }
-keepclasseswithmembers class com.bgallagher.rackoon.** { kotlinx.serialization.KSerializer serializer(...); }

# Spec files (commands.json, command-library.json, themes.json) are read as classpath resources by name.
-keepclassmembers class com.bgallagher.rackoon.core.SpecCommands { *; }
-adaptresourcefilenames **.json
