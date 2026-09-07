import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material, resolved in this order:
//   1. android/key.properties  — local release builds (gitignored)
//   2. CM_KEYSTORE_* env vars  — Codemagic injects these when the workflow's
//      `android_signing:` list references an uploaded keystore
//      (see codemagic.yaml + docs/ANDROID_DEPLOY.md)
//   3. nothing                 — fall back to debug keys so `flutter run
//      --release` still works on a dev box with no keystore
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

fun signingValue(propKey: String, envKey: String): String? =
    (keystoreProperties.getProperty(propKey) ?: System.getenv(envKey))
        ?.takeIf { it.isNotBlank() }

val releaseStorePath = signingValue("storeFile", "CM_KEYSTORE_PATH")

android {
    namespace = "com.ayma.ayma_flutter"
    // livekit_client's transitive connectivity_plus pulls androidx.core:core
    // 1.18, which needs compileSdk 36 + AGP 8.9.1 (bumped in settings.gradle.kts).
    compileSdk = 36
    // firebase_core / firebase_auth require NDK 27 (installed under ~/Android/Sdk/ndk/).
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ayma.ayma_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // minSdk 24: geolocator_android (Step 35); firebase_auth needs >= 23.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (releaseStorePath != null) {
                storeFile = file(releaseStorePath)
                storePassword = signingValue("storePassword", "CM_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "CM_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "CM_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Real upload key when a keystore is available (CI / local release),
            // otherwise debug keys so `flutter run --release` still works.
            signingConfig = if (releaseStorePath != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
