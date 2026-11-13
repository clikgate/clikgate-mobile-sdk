plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.vanniktech.publish) apply false
    alias(libs.plugins.binary.compatibility.validator)
}

// Public-API snapshot: clikgate/api/clikgate.api (core and its Engage features, com.clikgate.engage).
// `./gradlew apiCheck` (run by `check`) fails on any change; `./gradlew apiDump` updates them.
apiValidation {
    // :sample isn't a library (and isn't included when this build is part of a composite build).
    if (findProject(":sample") != null) ignoredProjects += listOf("sample")
}
