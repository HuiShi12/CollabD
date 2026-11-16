allprojects {
    repositories {
        google()
        mavenCentral()
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

    // Some plugins (e.g. opencv_dart 1.4.x) still pin an old compileSdk in
    // their own build.gradle, which fails the AAR-metadata check against
    // newer androidx. Force every Android library sub-project to a modern one.
    afterEvaluate {
        (extensions.findByName("android")
                as? com.android.build.api.dsl.LibraryExtension)
            ?.let { it.compileSdk = 36 }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
