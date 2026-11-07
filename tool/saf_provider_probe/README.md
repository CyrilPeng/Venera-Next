# Android SAF provider regression

The generated projects are confined to `build/dependency-followup/saf/android-probe`.
The provider and Flutter consumer use separate test package names:
`com.cyrilpeng.venera_saf_probe_provider` and `com.cyrilpeng.venera_saf_probe`.
Only an explicitly selected emulator can run the probe. Existing production
application data, permissions and logs are outside its operations.

Prepare/build with the app's Flutter SDK and Android SDK:

```sh
python tool/saf_provider_probe/prepare_probe.py --flutter /path/to/flutter --sdk /path/to/android-sdk --build
python .github/scripts/check_saf_bundle.py --root build/dependency-followup/saf/android-probe/consumer/build/app/outputs/flutter-apk
python tool/saf_provider_probe/prepare_probe.py --flutter /path/to/flutter --sdk /path/to/android-sdk --run --serial emulator-5554
```

On Windows, pass `flutter.bat` and use `READELF` to identify the Android NDK's
`llvm-readelf.exe`. Network proxy and Java settings apply only to the validation
process; the probe does not edit system configuration or caches. Its Gradle
build uses two workers and a 2 GiB heap limit. Android API 34 or newer is enough
for the test device; the app compiles against API 36 and NDK 28.0.13004108.

The consumer is a minified Release signed with a test debug key. Its native
packaging covers ARM32, ARM64 and x86_64. The script installs those two test APKs,
starts the `initial` phase, stops only the consumer, and starts `resume` without
clearing its persisted grants. Results and consumer-only logs are written to
`provider-probe.json`, `initial.log` and `resume.log`. A failed phase raises an
error; a screenshot alone is not considered a passing test.

The initial phase resets only the provider's own `filesDir/long` and
`filesDir/short` test directories, verifying their parent before recursive
cleanup. It exercises overlapping root IDs containing `/`, Chinese/emoji/pipe
names, typed views, creation without truncation, append, random-access ranges,
>2 GiB sparse operations, streaming cancellation, empty sinks, same-directory
rename, collision/root protection, normalized self-copy and different grants
sharing canonical document IDs, provider-changed names, remote close errors,
unavailable providers, grant revocation/regrant and duplicate authorities.
Provider counters independently check that the original ParcelFileDescriptor
stays open until the caller closes it. The resume phase checks saved paths and
persisted grants after process restart. Both phases require zero outstanding
native descriptors and balanced provider callbacks.

This provider is a deterministic Android fixture. External cloud vendors may
have further constraints; retain representative vendor/device evidence when
changing supported provider semantics. The CI job repeats the full fixture on
an isolated emulator and also verifies the packaged ABI and notice.
