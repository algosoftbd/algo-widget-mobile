// A standalone Gradle build needs its own plugin and dependency repositories —
// inside an app project these are inherited, which is why this file is easy to
// forget and why the failure ("plugin not found in any of the following
// sources") reads like a version problem rather than a missing settings file.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "algo-widget-android"
