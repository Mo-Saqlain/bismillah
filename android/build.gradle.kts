allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Redirect Gradle output OUT of OneDrive — OneDrive holds file locks while
// syncing, which breaks tasks like `mergeReleaseNativeLibs`. Set the env var
// `BISMILLAH_BUILD_DIR` to an absolute path outside OneDrive (e.g.
// C:\bismillah-build) before invoking `flutter build apk`.
val externalBuild: String? = System.getenv("BISMILLAH_BUILD_DIR")
val newBuildDir: Directory = if (externalBuild != null) {
    val abs = java.io.File(externalBuild).apply { mkdirs() }
    objects.directoryProperty().apply { set(abs) }.get()
} else {
    rootProject.layout.buildDirectory.dir("../../build").get()
}
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Force Android library subprojects to compile against a recent SDK.
    // `printing` (and a couple of others) pin a compileSdk too low to find
    // `android:attr/lStar`, which causes an AAPT error during release builds.
    // Registered here, before evaluationDependsOn forces evaluation below.
    afterEvaluate {
        if (project.plugins.hasPlugin("com.android.library")) {
            project.extensions.configure<com.android.build.gradle.LibraryExtension> {
                if ((compileSdk ?: 0) < 34) {
                    compileSdk = 34
                }
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
