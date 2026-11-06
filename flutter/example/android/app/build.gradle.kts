plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// App Link domain for the intent filter (autoVerify): -Pclikgate.linkDomain=inv.myapp.com
// (pass the same domain to Dart with --dart-define=CLIKGATE_LINK_DOMAIN=...).
val clikgateLinkDomain = (findProperty("clikgate.linkDomain") as String?) ?: "inv.example.com"

android {
    namespace = "com.clikgate.clikgate_flutter_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.clikgate.clikgate_flutter_example"
        // firebase_messaging (BoM 34+) needs 23; Flutter 3.35 defaults to 24.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["clikgateLinkDomain"] = clikgateLinkDomain
    }

    buildTypes {
        release {
            // Signing with the debug keys so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
