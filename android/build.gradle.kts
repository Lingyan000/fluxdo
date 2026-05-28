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
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 统一所有插件子项目的 Java 编译目标为 17，匹配 Kotlin 2.2 默认 JVM target。
// 解决部分插件（如 flutter_avif_android）仍声明 Java 11 导致的
// "Inconsistent JVM Target Compatibility" 构建失败。
// 必须在 afterEvaluate 内执行，否则 AGP 后续会用插件自带的 Java 11 覆盖。
subprojects {
    afterEvaluate {
        // 通过反射修改 android extension 的 compileOptions，避免 AGP import 依赖
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
        // 兜底：直接覆盖 JavaCompile task 的 target
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
