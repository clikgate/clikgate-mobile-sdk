pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "clikgate-android"

include(":clikgate")
// The sample app is skipped when this build is included in another build (e.g. the Flutter
// example's composite build), which only needs the library.
if (gradle.parent == null) {
    include(":sample")
}
