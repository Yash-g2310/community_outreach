plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_application_1"
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // Change applicationId to your chosen id. This is the app's package
        // identity on Android (Play Store, installers).
        applicationId = "com.erick.connect"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Optional: automatic APK renaming task. This attempts to rename the produced
// APK under build/outputs/flutter-apk to include a friendly name.
tasks.register("renameApk") {
    doLast {
        val outDir = File(buildDir, "outputs/flutter-apk")
        if (outDir.exists()) {
            outDir.listFiles()?.forEach { f ->
                if (f.extension == "apk") {
                    val newName = "E-Rick-Connect-${f.name}"
                    val renamed = File(outDir, newName)
                    if (!renamed.exists()) {
                        f.renameTo(renamed)
                        println("Renamed ${f.name} -> ${renamed.name}")
                    }
                }
            }
        }
    }
}

// Run renameApk after assembling release (this hooks into the assembleRelease task)
// Use matching/configureEach so the build doesn't fail when the task is absent.
tasks.matching { it.name == "assembleRelease" }.configureEach {
    finalizedBy(tasks.named("renameApk"))
}
