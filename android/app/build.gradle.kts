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
        versionCode = 1
        versionName = "0.1.0-alpha.1"
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
