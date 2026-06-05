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

        // 声明只要 64 位 ARM。真正剔除其它架构 .so 的是下方 packaging 块。
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // 只打 64 位 ARM，给「胖 APK」瘦身（约 79MB → 约 30MB）。
    // 关键就是这里：jniLibs.excludes 在打包阶段把所有非 arm64 的 .so 一律剔除，
    // 既包括 Flutter 自身的 libflutter.so / libapp.so（其它架构的大头），也包括
    // ML Kit(mobile_scanner) 等插件 AAR 里预打包、abiFilters 管不到的 armv7 / x86
    // 残留（主要是 libbarhopper_v3.so）。因此普通的 `flutter build apk --release`
    // 即可产出瘦身包，发布流程无需改动；想省构建时间可另加 --target-platform android-arm64。
    // 应用内更新只分发单个 APK，不能用 --split-per-abi（会拆成多个包、装错架构）。
    // 注意：2017 年前的纯 32 位老机型将无法安装。
    packaging {
        jniLibs {
            excludes += setOf("**/armeabi-v7a/**", "**/x86/**", "**/x86_64/**")
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
