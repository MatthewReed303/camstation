plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.matthewreed303.camstation"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.matthewreed303.camstation"
        // 24 covers Android 8.0 (26) and up.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The bundled engine (jniLibs/<abi>/libgo2rtc.so) must be extracted to
    // nativeLibraryDir: it is executed with Process.start, not dlopen'ed.
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // The engine is a Go executable, not a library: never let the
            // release build strip/rewrite it (keeps its pinned SHA-256 too).
            keepDebugSymbols += "**/libgo2rtc.so"
        }
    }

    // Release signing from the environment, never from files in the repo:
    // CAMSTATION_KEYSTORE, CAMSTATION_KEYSTORE_PASSWORD, CAMSTATION_KEY_ALIAS,
    // CAMSTATION_KEY_PASSWORD. Without them, release builds use the debug key.
    val releaseKeystore = System.getenv("CAMSTATION_KEYSTORE")
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("CAMSTATION_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("CAMSTATION_KEY_ALIAS")
                keyPassword = System.getenv("CAMSTATION_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }
}

// Release builds are ARM only: arm64 for current phones, armv7 for older
// 32-bit ones (many Android 8 devices). x86_64 stays in debug builds for the
// emulator: Go's amd64 build fails Play's 16 KB page-size check.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.add("lib/x86_64/**")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
