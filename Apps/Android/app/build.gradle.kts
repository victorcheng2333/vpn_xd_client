import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Single version source shared with macOS and iOS: Resources/Info.plist at the repository root.
// BUILD_CHANNEL / BUILD_NUMBER follow scripts/version.py; release builds take the plist build number only.
val infoPlist = rootDir.resolve("../../Resources/Info.plist").readText()
fun plistString(key: String) = Regex("<key>$key</key>\\s*<string>([^<]+)</string>").find(infoPlist)?.groupValues?.get(1)
    ?: throw GradleException("Missing $key in Resources/Info.plist")
val sourceVersion = plistString("CFBundleShortVersionString")
val buildChannel = System.getenv("BUILD_CHANNEL") ?: "development"
if (buildChannel !in setOf("development", "test", "release")) throw GradleException("Invalid build channel")
val buildNumber = System.getenv("BUILD_NUMBER")?.takeIf { buildChannel != "release" } ?: plistString("CFBundleVersion")
if (!Regex("[1-9][0-9]{0,8}").matches(buildNumber)) throw GradleException("BUILD_NUMBER must be a positive integer of at most 9 digits.")
val displayVersion = if (buildChannel == "release") sourceVersion else "$sourceVersion-${if (buildChannel == "development") "dev" else "test"}.$buildNumber"

// Release signing: signing.properties or ANDROID_KEYSTORE_* first. Without either, the local debug keystore is
// used so devices that carry the development-signed builds can upgrade in place. The choice is recorded in
// assets/xdvpn-version.json and printed; it is never silent.
data class Signing(val kind: String, val store: File, val storePassword: String, val alias: String, val keyPassword: String)
val signing: Signing? = run {
    val props = Properties()
    rootDir.resolve("signing.properties").takeIf { it.isFile }?.inputStream()?.use(props::load)
    fun value(property: String, variable: String) = props.getProperty(property) ?: System.getenv(variable)
    val store = value("storeFile", "ANDROID_KEYSTORE_FILE")
    if (store != null) Signing("configured", rootDir.resolve(store),
        value("storePassword", "ANDROID_KEYSTORE_PASSWORD") ?: throw GradleException("Missing keystore password"),
        value("keyAlias", "ANDROID_KEY_ALIAS") ?: throw GradleException("Missing key alias"),
        value("keyPassword", "ANDROID_KEY_PASSWORD") ?: throw GradleException("Missing key password"))
    else File(System.getProperty("user.home"), ".android/debug.keystore").takeIf { it.isFile }
        ?.let { Signing("development", it, "android", "androiddebugkey", "android") }
}
logger.lifecycle("XD VPN Android $displayVersion (versionCode $buildNumber, channel $buildChannel), release signing: ${signing?.kind ?: "none"}")

android {
    namespace = "com.xd.vpn.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.xd.vpn.android"
        minSdk = 28
        targetSdk = 36
        versionCode = buildNumber.toInt()
        versionName = displayVersion
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    sourceSets["main"].jniLibs.srcDir("../.build/jniLibs")
    sourceSets["main"].assets.srcDir("../.build/assets")
    packaging { jniLibs.useLegacyPackaging = false }
    signingConfigs {
        signing?.let { create("release") { storeFile = it.store; storePassword = it.storePassword; keyAlias = it.alias; keyPassword = it.keyPassword } }
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
    }
    lint { abortOnError = true }
}
kotlin { compilerOptions { jvmTarget.set(JvmTarget.JVM_17) } }
val buildEngine by tasks.registering(Exec::class) {
    workingDir(rootDir)
    commandLine("bash", "scripts/build-engine.sh")
}
// Lets release verification read the embedded version without the Android SDK (scripts/verify-release-apk.py).
val versionAsset = rootDir.resolve(".build/assets/xdvpn-version.json")
val writeVersionAsset by tasks.registering {
    val content = """{"version":"$sourceVersion","build":$buildNumber,"channel":"$buildChannel","displayVersion":"$displayVersion","signing":"${signing?.kind ?: "unsigned"}"}"""
    inputs.property("content", content)
    outputs.file(versionAsset)
    doLast { versionAsset.parentFile.mkdirs(); versionAsset.writeText(content + "\n") }
}
tasks.named("preBuild").configure { dependsOn(buildEngine, writeVersionAsset) }
dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.05.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.core:core-ktx:1.16.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.05.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
