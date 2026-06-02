allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // 统一所有插件子项目的 Java/Kotlin 编译目标为 17，匹配 Kotlin 2.2 默认 JVM target。
    // 解决部分插件（如 flutter_avif_android 声明 Java 11、audio_session 声明 Kotlin 11）导致的
    // "Inconsistent JVM Target Compatibility" 构建失败。
    // 必须在 evaluationDependsOn 之前注册 afterEvaluate，否则项目已评估完无法再 hook。
    afterEvaluate {
        // 1. 通过反射修改 android extension 的 compileOptions，避免 AGP import 依赖
        extensions.findByName("android")?.let { androidExt ->
            try {
                val compileOptions = androidExt.javaClass
                    .getMethod("getCompileOptions")
                    .invoke(androidExt)
                compileOptions.javaClass
                    .getMethod("setSourceCompatibility", Any::class.java)
                    .invoke(compileOptions, JavaVersion.VERSION_17)
                compileOptions.javaClass
                    .getMethod("setTargetCompatibility", Any::class.java)
                    .invoke(compileOptions, JavaVersion.VERSION_17)
            } catch (_: Exception) {
                // 非 Android 子项目，跳过
            }
        }
        // 2. 兜底：直接覆盖 JavaCompile task 的 target
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
        // 3. 兜底：覆盖 Kotlin compile task 的 jvmTarget（task 名形如 compileReleaseKotlin）
        //    用名字匹配 + 反射，避免 import KGP
        tasks.matching {
            it.name.startsWith("compile") && it.name.endsWith("Kotlin")
        }.configureEach {
            val task = this
            try {
                val kotlinOptions = task.javaClass
                    .getMethod("getKotlinOptions")
                    .invoke(task)
                kotlinOptions.javaClass
                    .getMethod("setJvmTarget", String::class.java)
                    .invoke(kotlinOptions, "17")
            } catch (_: Exception) {
                // 不是 Kotlin compile task 或 API 不可用，跳过
            }
        }

        // 4. flutter_avif_android 3.1.0 同时存在 FlutterAvifPlugin.java 和 .kt
        //    新版 Kotlin compiler 会报 Redeclaration 错误。在编译前删除多余的 Java 版。
        if (project.name == "flutter_avif_android") {
            val patchTask = tasks.register("patchFlutterAvifPluginRedeclaration") {
                doFirst {
                    val javaFile = file(
                        "src/main/java/com/teknorota/flutter_avif/FlutterAvifPlugin.java"
                    )
                    if (javaFile.exists()) {
                        javaFile.delete()
                        logger.lifecycle(
                            "Patched flutter_avif_android: removed duplicate ${javaFile.name}"
                        )
                    }
                }
            }
            tasks.matching { it.name.startsWith("compile") }.configureEach {
                dependsOn(patchTask)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
