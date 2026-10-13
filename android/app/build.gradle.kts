plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.bgallagher.rackoon"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.bgallagher.rackoon"
        minSdk = 26
        targetSdk = 36
        // CI sets these from the tag (android-v0.1.0-alpha.1 -> 0.1.0-alpha.1) and the commit count (it only ever goes up);
        // a local build uses the defaults.
        versionCode = System.getenv("ANDROID_VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("ANDROID_VERSION_NAME") ?: "0.1.0-alpha.1"
    }

    // The release key is never in the repo: CI writes it from a secret and points these variables at it. Without them (a local
    // build) the release APK is simply left unsigned.
    val keystore = System.getenv("ANDROID_KEYSTORE_FILE")
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (keystore != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    buildFeatures { compose = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources {
            excludes += setOf("META-INF/versions/**", "META-INF/DEPENDENCIES", "META-INF/*.kotlin_module", "META-INF/MANIFEST.MF", "META-INF/LICENSE*", "META-INF/NOTICE*", "META-INF/INDEX.LIST")
        }
    }
}

dependencies {
    implementation(project(":ssh"))
    runtimeOnly(libs.slf4j.nop)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation("org.connectbot:termlib:0.3.13")
}
