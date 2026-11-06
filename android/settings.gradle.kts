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
// Optional Engage add-on (17A): depends on :clikgate, never the other way round.
include(":clikgate-engage")
// The sample app is skipped when this build is included in another build (e.g. the Flutter
// example's composite build), which only needs the library.
if (gradle.parent == null) {
    include(":sample")
}
