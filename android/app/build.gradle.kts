plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.chunyikit.wo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.chunyikit.wo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 极光推送占位符：被 jpush_flutter 合并进来的 manifest meta-data 引用。
        // AppKey 必须与极光控制台、后端 JPUSH_APP_KEY 一致；包名已注册为 applicationId。
        manifestPlaceholders["JPUSH_PKGNAME"] = "io.github.chunyikit.wo"
        manifestPlaceholders["JPUSH_APPKEY"] = "c7b049b2dae09a723655dc8e"
        manifestPlaceholders["JPUSH_CHANNEL"] = "default_developer"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
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
