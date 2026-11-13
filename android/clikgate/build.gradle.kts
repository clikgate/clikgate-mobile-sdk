import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.vanniktech.publish)
}

val sdkVersion = providers.gradleProperty("VERSION_NAME").get()

android {
    namespace = "com.clikgate"
    compileSdk = 36

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
        buildConfigField("String", "SDK_VERSION", "\"$sdkVersion\"")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            // Libraries are shrunk by the consuming app (consumer-rules.pro ships with the AAR).
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
        // Unit tests read the shared contract fixtures straight from ../shared (classpath
        // resources "fixtures/<name>.json"), so there is a single copy of every payload.
        getByName("test").resources.srcDir(rootProject.file("../shared"))
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
    }
}

kotlin {
    // Explicit API mode for the library sources only (not tests).
    explicitApi()
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
        // Emit metadata readable by apps still on Kotlin 1.9 (common in Flutter apps).
        apiVersion.set(KotlinVersion.KOTLIN_1_9)
        languageVersion.set(KotlinVersion.KOTLIN_1_9)
        freeCompilerArgs.add("-Xjvm-default=all")
    }
}

dependencies {
    implementation(libs.installreferrer)
    implementation(libs.androidx.core)
    implementation(libs.work.runtime)
    implementation(libs.lifecycle.process)

    // Optional: used only when the app itself depends on Play Integrity and enables it.
    compileOnly(libs.play.integrity)
    compileOnly(libs.play.services.tasks)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.work.testing)
    testImplementation(libs.coroutines.test)
}

mavenPublishing {
    publishToMavenCentral(automaticRelease = false)
    // Signs only when signing keys are configured (CI release job); local builds stay unsigned.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) {
        signAllPublications()
    }
    coordinates("com.clikgate", "clikgate-android", sdkVersion)
}

// Spec 0.4, kept after the merge (2.1.0): the Engage features ship in this artifact under com.clikgate.engage,
// but core code never uses them (Engage uses core, never the other way round). Fails if any source outside
// com/clikgate/engage refers to com.clikgate.engage. Part of `check`.
val checkNoEngageDependency by tasks.registering {
    group = "verification"
    description = "Fails if core code (outside com.clikgate.engage) refers to the Engage features."
    val sources = fileTree("src/main") {
        include("**/*.kt", "**/*.java")
        exclude("java/com/clikgate/engage/**")
    }
    inputs.files(sources)
    doLast {
        val imports = sources.files.filter { f -> f.readText().contains("com.clikgate.engage") }
        check(imports.isEmpty()) { "Core sources reference com.clikgate.engage: $imports" }
        logger.lifecycle("checkNoEngageDependency: OK (${sources.files.size} core sources)")
    }
}
tasks.named("check") { dependsOn(checkNoEngageDependency) }

// AGP puts src/main/java in both the Java and the Kotlin source sets, so the sources jar listed every
// file twice: a zip with duplicate entries, which strict readers (and the release scan) reject.
// (The task is an org.gradle.jvm.tasks.Jar, not the bundling Jar this script imports by default.)
tasks.withType<org.gradle.jvm.tasks.Jar>().matching { it.name.endsWith("SourcesJar") }.configureEach {
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    // Its two child copy specs (Java and Kotlin dirs) set INCLUDE themselves; the per-file strategy wins.
    eachFile { duplicatesStrategy = DuplicatesStrategy.EXCLUDE }
}
