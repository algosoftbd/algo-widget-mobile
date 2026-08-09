// Android capture core for the Algo Widget (docs/PROTOCOL.md).
//
// Deliberately thin. Everything that CAN be done above the platform is done in
// the Flutter and React Native packages, in a language that can be tested
// without a device. What lives here is only what cannot: screen capture, audio,
// screenshots, the uncaught-exception handler, and hosting the WebView that
// runs the existing report UI.
plugins {
    id("com.android.library") version "8.7.3"
    id("org.jetbrains.kotlin.android") version "2.0.21"
}

android {
    namespace = "com.algosoft.widget"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { buildConfig = false }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.webkit:webkit:1.12.1")
    testImplementation("junit:junit:4.13.2")
}
