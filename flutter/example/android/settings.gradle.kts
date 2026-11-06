pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")

// Monorepo development: build the native Clikgate SDK from ../../../android (composite build)
// instead of downloading com.clikgate:clikgate-android from Maven Central. Disable with
// -Pclikgate.useLocalSdk=false to test against the published artifact.
val clikgateAndroidSdk = file("../../../android")
if (clikgateAndroidSdk.resolve("settings.gradle.kts").exists() &&
    providers.gradleProperty("clikgate.useLocalSdk").orNull != "false"
) {
    includeBuild(clikgateAndroidSdk) {
        dependencySubstitution {
            substitute(module("com.clikgate:clikgate-android")).using(project(":clikgate"))
            // clikgate_engage's native share bridge
            substitute(module("com.clikgate:clikgate-engage")).using(project(":clikgate-engage"))
        }
    }
}
