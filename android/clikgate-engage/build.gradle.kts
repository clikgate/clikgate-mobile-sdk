import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.vanniktech.publish)
}

val sdkVersion = providers.gradleProperty("VERSION_NAME").get()

android {
    namespace = "com.clikgate.engage"
    compileSdk = 36

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
        buildConfigField("String", "ENGAGE_VERSION", "\"$sdkVersion\"")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
        }
    }

    sourceSets {
        // Contract fixtures straight from ../shared (classpath resources "fixtures/<name>.json").
        getByName("test").resources.srcDir(rootProject.file("../shared"))
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
    }
}

kotlin {
    explicitApi()
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
        apiVersion.set(KotlinVersion.KOTLIN_1_9)
        languageVersion.set(KotlinVersion.KOTLIN_1_9)
        freeCompilerArgs.add("-Xjvm-default=all")
        // Engage uses core's internal request context (Clikgate.requestContext / reportServerError).
        optIn.add("com.clikgate.ClikgateInternalApi")
        // Size (budget < 44 KB): no generated Intrinsics null checks on parameters / call results.
        freeCompilerArgs.addAll("-Xno-param-assertions", "-Xno-call-assertions", "-Xno-receiver-assertions")
    }
}

dependencies {
    // Apps that add Engage get the core SDK transitively. Core never depends on Engage.
    api(project(":clikgate"))

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.androidx.test.core)
}

mavenPublishing {
    publishToMavenCentral(automaticRelease = false)
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }
    coordinates("com.clikgate", "clikgate-engage", sdkVersion)
    pom {
        name.set("Clikgate Engage (Android)")
        description.set(
            "Optional Clikgate add-on for apps without their own backend: referral links and stats, " +
                "leaderboards, promo codes and share helpers. Depends on com.clikgate:clikgate-android.",
        )
    }
}
