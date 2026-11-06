plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

// Configure with -P or ~/.gradle/gradle.properties:
//   clikgate.sdkKey=cg_sdk_...  clikgate.apiBaseUrl=http://10.0.2.2:8000  clikgate.linkDomain=inv.myapp.com
//   clikgate.programId=rpg_...
// Push (optional; FCM without google-services.json):
//   clikgate.firebaseApiKey=...  clikgate.firebaseAppId=...  clikgate.firebaseProjectId=...  clikgate.firebaseSenderId=...
fun prop(name: String, default: String) = (findProperty(name) as String?) ?: default
val linkDomain = prop("clikgate.linkDomain", "inv.example.com")

android {
    namespace = "com.clikgate.sample"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.clikgate.sample"
        minSdk = 24 // Firebase Messaging (BoM 35) needs 24; the SDK itself supports 21
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        manifestPlaceholders["clikgateLinkDomain"] = linkDomain
        buildConfigField("String", "CLIKGATE_SDK_KEY", "\"${prop("clikgate.sdkKey", "cg_sdk_sample")}\"")
        buildConfigField("String", "CLIKGATE_API_BASE_URL", "\"${prop("clikgate.apiBaseUrl", "https://sdk.clikgate.com")}\"")
        buildConfigField("String", "CLIKGATE_LINK_DOMAIN", "\"$linkDomain\"")
        buildConfigField("String", "CLIKGATE_PROGRAM_ID", "\"${prop("clikgate.programId", "rpg_sample")}\"")
        buildConfigField("String", "FIREBASE_API_KEY", "\"${prop("clikgate.firebaseApiKey", "")}\"")
        buildConfigField("String", "FIREBASE_APP_ID", "\"${prop("clikgate.firebaseAppId", "")}\"")
        buildConfigField("String", "FIREBASE_PROJECT_ID", "\"${prop("clikgate.firebaseProjectId", "")}\"")
        buildConfigField("String", "FIREBASE_SENDER_ID", "\"${prop("clikgate.firebaseSenderId", "")}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

dependencies {
    implementation(project(":clikgate"))
    // Optional Engage add-on: invite link, stats and WhatsApp share without a backend.
    implementation(project(":clikgate-engage"))
    // FCM without the google-services plugin: the app builds and runs without
    // google-services.json; push registration is skipped when Firebase isn't configured.
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
    // Change 03: Firebase Analytics receives Clikgate attribution (Clikgate.enableFirebaseForwarding).
    // runtimeOnly: the SDK finds it by reflection, and the sample never calls it (its 24.x Kotlin metadata
    // is newer than this build's Kotlin 2.1 compiler accepts).
    runtimeOnly(libs.firebase.analytics)

    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.core)
}
