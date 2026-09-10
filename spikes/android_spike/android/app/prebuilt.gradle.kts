import java.io.File

plugins {
    id("com.android.application")
    id("kotlin-android")
}

// Frozen artifacts are the only Dart/native Engine inputs in this mode.
// In particular, no Flutter Gradle plugin or flutter assemble task runs here.
val prebuiltPath = providers.gradleProperty("hotfix.prebuilt").get()
val prebuiltRoot = File(prebuiltPath)
require(prebuiltRoot.isAbsolute) { "hotfix.prebuilt must be an absolute directory" }
layout.buildDirectory.set(rootProject.layout.buildDirectory.dir("prebuilt-app"))

val validatePrebuiltHotfix = tasks.register("validatePrebuiltHotfix") {
    doLast {
        for (name in listOf("libflutter.so", "libapp.so")) {
            val artifact = prebuiltRoot.resolve("lib/arm64-v8a/$name")
            check(artifact.isFile && artifact.length() > 0) {
                "Missing or empty prebuilt artifact: $artifact"
            }
        }
        check(prebuiltRoot.resolve("assets/flutter_assets").isDirectory) {
            "Missing prebuilt assets/flutter_assets directory: $prebuiltRoot"
        }
        check(!prebuiltRoot.resolve("lib/arm64-v8a/libpatch_store_io.so").exists()) {
            "native store must be built from native/CMakeLists.txt, not supplied twice"
        }
    }
}
tasks.named("preBuild") { dependsOn(validatePrebuiltHotfix) }

repositories {
    // Same pinned embedding and transitive POM as the default Flutter build.
    // --offline consumes the existing Gradle cache without network access.
    maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
}

android {
    namespace = "dev.hotfixruntime.android_spike"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "dev.hotfixruntime.android_spike"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
        manifestPlaceholders["applicationName"] = "android.app.Application"
        ndk { abiFilters += "arm64-v8a" }
    }

    externalNativeBuild {
        cmake {
            path = file("../../../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets.getByName("main") {
        jniLibs.srcDir(prebuiltRoot.resolve("lib"))
        assets.srcDir(prebuiltRoot.resolve("assets"))
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = JavaVersion.VERSION_17.toString() }

    packaging {
        jniLibs {
            keepDebugSymbols += "**/*.so"
            useLegacyPackaging = false
        }
    }

    buildTypes {
        release {
            // Host-built development APK only; no production signing key here.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation("io.flutter:flutter_embedding_release:1.0.0-42d3d75a56efe1a2e9902f52dc8006099c45d937")
}
