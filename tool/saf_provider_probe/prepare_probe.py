"""Build and run isolated, minified Android document-provider regressions."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent
CLIENT = "com.cyrilpeng.venera_saf_probe"
PROVIDER = "com.cyrilpeng.venera_saf_probe_provider"


def run(command, cwd=None, capture=False):
    result = subprocess.run([str(value) for value in command], cwd=cwd, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout.decode("utf-8", errors="replace").strip() if capture else None


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def prepare(output, flutter, sdk):
    consumer = output / "consumer"
    provider = output / "provider"
    if not (consumer / ".metadata").is_file():
        run([flutter, "create", "--empty", "--platforms", "android", "--no-pub",
             "--project-name", "venera_saf_probe", "--org", "com.cyrilpeng", consumer])
    write(consumer / "pubspec.yaml", f"""name: venera_saf_probe
publish_to: none
version: 1.0.0+1
environment:
  sdk: '>=3.8.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  venera_saf:
    path: '{(ROOT / 'packages/venera_saf').as_posix()}'
dev_dependencies:
  flutter_lints: ^6.0.0
flutter:
  uses-material-design: true
""")
    write(consumer / "lib/main.dart", (SOURCE / "consumer.dart.template").read_text(encoding="utf-8"))
    write(consumer / "android/gradle.properties", "org.gradle.jvmargs=-Xmx2048M -XX:MaxMetaspaceSize=512M\n"
          "org.gradle.workers.max=2\nandroid.useAndroidX=true\n")
    write(consumer / "android/app/src/main/kotlin/com/cyrilpeng/venera_saf_probe/MainActivity.kt",
          (SOURCE / "ConsumerActivity.kt").read_text(encoding="utf-8"))
    android = "http://schemas.android.com/apk/res/android"
    ET.register_namespace("android", android)
    application_manifest = consumer / "android/app/src/main/AndroidManifest.xml"
    manifest = ET.parse(application_manifest)
    queries = manifest.getroot().find("queries")
    if queries is None: queries = ET.SubElement(manifest.getroot(), "queries")
    for tag, attribute, value in (("package", "name", PROVIDER),
                                  ("provider", "authorities", PROVIDER + ".control")):
        key = "{" + android + "}" + attribute
        if not any(child.get(key) == value for child in queries.findall(tag)):
            ET.SubElement(queries, tag, {key: value})
    ET.indent(manifest, space="    ")
    manifest.write(application_manifest, encoding="utf-8", xml_declaration=False)
    write(consumer / "android/app/build.gradle.kts", """plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}
android {
    namespace = "com.cyrilpeng.venera_saf_probe"
    compileSdk = 36
    ndkVersion = "28.0.13004108"
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    defaultConfig {
        applicationId = "com.cyrilpeng.venera_saf_probe"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
        ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64") }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
}
flutter { source = "../.." }
""")
    write(provider / "settings.gradle", """pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
plugins {
    id 'com.android.application' version '8.12.3' apply false
    id 'org.jetbrains.kotlin.android' version '2.1.0' apply false
}
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = 'VeneraSafProbeProvider'
include ':app'
""")
    write(provider / "gradle.properties", "org.gradle.jvmargs=-Xmx2048M\norg.gradle.workers.max=2\nandroid.useAndroidX=true\n")
    write(provider / "local.properties", "sdk.dir=" + sdk.as_posix() + "\n")
    write(provider / "app/build.gradle", """plugins { id 'com.android.application'; id 'org.jetbrains.kotlin.android' }
android {
    namespace 'com.cyrilpeng.venera_saf_probe_provider'
    compileSdk 36
    defaultConfig { applicationId 'com.cyrilpeng.venera_saf_probe_provider'; minSdk 24; targetSdk 36; versionCode 1; versionName '1.0.0' }
    compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = '17' }
}
""")
    write(provider / "app/src/main/kotlin/com/cyrilpeng/venera_saf_probe_provider/Provider.kt",
          (SOURCE / "Provider.kt").read_text(encoding="utf-8"))
    write(provider / "app/src/main/AndroidManifest.xml", """<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application android:label="Venera SAF provider probe" android:theme="@android:style/Theme.Material.Light.NoActionBar">
    <activity android:name=".GrantActivity" android:exported="true" />
    <provider android:name=".ProbeDocumentsProvider" android:authorities="com.cyrilpeng.venera_saf_probe_provider.documents"
      android:exported="true" android:grantUriPermissions="true" android:permission="android.permission.MANAGE_DOCUMENTS">
      <intent-filter><action android:name="android.content.action.DOCUMENTS_PROVIDER" /></intent-filter>
    </provider>
    <provider android:name=".ProbeAliasDocumentsProvider" android:authorities="com.cyrilpeng.venera_saf_probe_provider.alias"
      android:exported="true" android:grantUriPermissions="true" android:permission="android.permission.MANAGE_DOCUMENTS">
      <intent-filter><action android:name="android.content.action.DOCUMENTS_PROVIDER" /></intent-filter>
    </provider>
    <provider android:name=".ProbeControlProvider" android:authorities="com.cyrilpeng.venera_saf_probe_provider.control" android:exported="true" />
  </application>
</manifest>
""")
    for relative in ("gradlew", "gradlew.bat", "gradle/wrapper/gradle-wrapper.jar", "gradle/wrapper/gradle-wrapper.properties"):
        target = provider / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        original = ROOT / "android" / relative
        if not original.is_file(): original = consumer / "android" / relative
        shutil.copyfile(original, target)
    if os.name != "nt": (provider / "gradlew").chmod(0o755)
    return consumer, provider


def execute(output, sdk, serial):
    if not serial or not serial.startswith("emulator-"):
        raise ValueError("Pass an explicit task emulator serial; physical devices are excluded")
    adb = sdk / "platform-tools" / ("adb.exe" if os.name == "nt" else "adb")
    command = [adb, "-s", serial]
    if run(command + ["shell", "getprop", "ro.kernel.qemu"], capture=True) != "1":
        raise ValueError("The selected device is not a task emulator")
    run(command + ["shell", "am", "force-stop", CLIENT])
    for apk in (output / "provider/app/build/outputs/apk/debug/app-debug.apk",
                output / "consumer/build/app/outputs/flutter-apk/app-release.apk"):
        run(command + ["install", "-r", apk])
    reports = []
    for phase in ("initial", "resume"):
        run(command + ["shell", "am", "force-stop", CLIENT])
        run(command + ["shell", "am", "start", "-W", "-n", CLIENT + "/.MainActivity", "--es", "phase", phase])
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            pid = run(command + ["shell", "pidof", CLIENT], capture=True)
            logs = run(command + ["logcat", "-d", "-v", "raw", "--pid=" + pid], capture=True) if pid else ""
            write(output / (phase + ".log"), logs)
            lines = [line.partition("VENERA_SAF_PROBE_RESULT ")[2] for line in logs.splitlines()
                     if "VENERA_SAF_PROBE_RESULT " in line]
            if lines:
                report = json.loads(lines[-1])
                reports.append(report)
                write(output / "provider-probe.json", json.dumps(reports, ensure_ascii=False, indent=2) + "\n")
                if report.get("ok") is not True or report.get("phase") != phase:
                    raise RuntimeError(json.dumps(report, ensure_ascii=False))
                print(json.dumps(report, ensure_ascii=False), flush=True)
                break
            time.sleep(2)
        else:
            raise TimeoutError(f"Provider probe did not complete phase {phase}; inspect {output / (phase + '.log')}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, default=ROOT / "build/dependency-followup/saf/android-probe")
    parser.add_argument("--flutter", default=shutil.which("flutter"))
    parser.add_argument("--sdk", type=Path, default=os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT"))
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--serial")
    args = parser.parse_args()
    output = args.workspace.resolve()
    if not output.is_relative_to(ROOT / "build") or output == ROOT / "build":
        raise ValueError("Probe output must remain in this repository's build directory")
    if not args.flutter or not args.sdk: raise ValueError("Flutter and an Android SDK must be specified")
    sdk = args.sdk.resolve()
    consumer, provider = prepare(output, args.flutter, sdk)
    if args.build:
        wrapper = provider / ("gradlew.bat" if os.name == "nt" else "gradlew")
        run([wrapper, "assembleDebug", "--no-daemon"], cwd=provider)
        run([args.flutter, "pub", "get"], cwd=consumer)
        run([args.flutter, "build", "apk", "--release", "--no-pub", "--target-platform", "android-arm,android-arm64,android-x64"], cwd=consumer)
    if args.run: execute(output, sdk, args.serial)
    print(f"Probe workspace: {output}")


if __name__ == "__main__": main()
