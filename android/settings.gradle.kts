pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "rackoon-android"
include(":core")
include(":ssh")
include(":probe")
include(":app")
