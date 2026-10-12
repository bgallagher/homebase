import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// The real-server checks (like apple's rackoon-probe): ./gradlew :probe:run --args="<host> <check>"
// Every check is read-only or works on a throwaway /tmp folder; none changes the server.
plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":ssh"))
}

application {
    mainClass.set("com.bgallagher.rackoon.probe.MainKt")
}
