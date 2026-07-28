import java.io.File
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

fun Properties.readNonBlank(name: String): String? =
    getProperty(name)?.trim()?.takeIf { it.isNotEmpty() }

fun resolveStoreFile(pathValue: String?): File? {
    val normalized = pathValue?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val directFile = File(normalized)
    if (directFile.isAbsolute) {
        return directFile
    }

    val candidates = linkedSetOf(
        file(normalized),
        rootProject.file(normalized),
    )
    return candidates.firstOrNull { it.exists() } ?: candidates.firstOrNull()
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(keystorePropertiesFile.inputStream())
    }
}
val releaseKeyAlias = keystoreProperties.readNonBlank("keyAlias")
val releaseKeyPassword = keystoreProperties.readNonBlank("keyPassword")
val releaseStorePassword = keystoreProperties.readNonBlank("storePassword")
val releaseStoreFile = resolveStoreFile(keystoreProperties.readNonBlank("storeFile"))
val hasReleaseSigning =
    releaseKeyAlias != null &&
    releaseKeyPassword != null &&
    releaseStorePassword != null &&
    releaseStoreFile?.exists() == true &&
    (releaseStoreFile?.length() ?: 0L) > 0L
val releaseBuildSigningName = if (hasReleaseSigning) "release" else "debug"

println(
    if (hasReleaseSigning) {
        "Android local signing: using ${releaseStoreFile?.path} for debug/profile/release"
    } else {
        "Android local signing: incomplete config, debug uses default debug signing and profile/release fallback to debug signing"
    }
)

android {
    namespace = "com.github.lingyan000.fluxdo"
    compileSdk = flutter.compileSdkVersion
    // 显式锁定 Flutter 3.44 默认 NDK，配合 CI 预装与 subprojects 强制统一，
    // 避免插件 side-by-side 再拉 27.x 导致重复下载。
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.github.lingyan000.fluxdo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                // 启用 V1 (JAR signing) + V2 (APK Signature Scheme v2) + V3 (APK Signature Scheme v3)
                // V1: 兼容 Android 6.x 及以下
                // V2: Android 7.0+ 快速校验
                // V3: Android 9.0+ 支持密钥轮转
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
                enableV4Signing = true  // Android 11+ 增量更新优化（可选）
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(releaseBuildSigningName)
            // 关闭 R8 代码压缩与资源压缩：开启后 Release 包运行时闪退，
            // 在定位到具体被裁剪的类之前保持禁用状态。
            isMinifyEnabled = false
            isShrinkResources = false
        }

        debug {
            signingConfig = signingConfigs.getByName(releaseBuildSigningName)
        }

        getByName("profile") {
            signingConfig = signingConfigs.getByName(releaseBuildSigningName)
        }
    }

    // 显式根据构建目标过滤 ABI，防止 Cronet 等原生库引入不需要的架构
    val targetPlatform = project.findProperty("target-platform") as? String
    println("Target Platform: $targetPlatform")
    if (targetPlatform != null) {
        val targetAbi = when (targetPlatform) {
            "android-arm" -> "armeabi-v7a"
            "android-arm64" -> "arm64-v8a"
            "android-x64" -> "x86_64"
            else -> null
        }

        if (targetAbi != null) {
            println("Configuring build for ABI: $targetAbi")
            defaultConfig {
                ndk {
                    abiFilters.add(targetAbi)
                }
            }
            
            // 强制排除非目标架构的 so 文件 (针对 Cronet 等不服从 abiFilters 的库)
            packaging {
                jniLibs {
                    val allAbis = listOf("armeabi-v7a", "arm64-v8a", "x86_64", "x86")
                    allAbis.filter { it != targetAbi }.forEach { abi ->
                        excludes.add("lib/$abi/**")
                    }
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation(platform("com.google.firebase:firebase-bom:33.14.0"))
    implementation("com.google.firebase:firebase-crashlytics-ndk")
    implementation("com.google.firebase:firebase-analytics")
    implementation("org.json:json:20240303")
    implementation("androidx.webkit:webkit:1.15.0")
    // 媒体转码(压缩到 4MB):Transformer 走系统 MediaCodec 硬编
    implementation("androidx.media3:media3-transformer:1.10.1")
    implementation("androidx.media3:media3-effect:1.10.1")
    implementation("androidx.media3:media3-common:1.10.1")
}
