# Running and Maintaining Tests

Default Chinese version: [testing.zh.md](testing.zh.md)

This guide covers test ownership, local execution, CI evidence, and regression maintenance. See [Build and Development](build.en.md) for toolchains and [Dependency Governance](dependencies.en.md) for sources and patches. The reorganization baseline, decisions, and acceptance record are in [experiments](../experiments/test_reorganization_plan_20261113.zh.md).

## Environment and Entry Points

Run commands from the repository root with Flutter 3.41.4 from `pubspec.yaml`, the checked-in lockfile, and Python 3. Native regressions also require the target platform toolchain. `rust-toolchain.toml` pins Rust 1.92.0; Flutter Rust Bridge stays at 2.11.1. HarmonyOS uses its [independently pinned SDK and controlled dependencies](harmonyos_releases.en.md).

`test/suites.json` owns execution. Keep business tests in `test/features/<feature>/`, `test/foundation/`, and the existing module directories. Put module helpers in that module's `support/`, shared helpers in `test/support/`, and real subprocess entrypoints and compatibility fixtures in `test/fixtures/`. Strict ownership checks reject imports of other `*_test.dart` files for helpers. The PhotoView package `main()` wrapper is an explicitly recorded exception.

| Entry | Contents and environment |
| --- | --- |
| `default` | All root Flutter regressions, with native libraries prepared on the applicable host |
| `fast` / `--partition fast` | Reviewed logic and component files that need no custom native-library build, for early feedback |
| `--partition shard-1`, etc. | Complete file groups covering default minus fast, balanced using measured weights; the manifest sets the shard count |
| `windows` | Windows behavior, real ABI, WebView, window lifecycle, and consumers of their helpers |
| `tv` | Real TV flavor and declared compilation arguments, with separate input, low-memory, and update checks |
| `harmonyos-host` | Linux host regressions executed in the prepared HarmonyOS project with its fixed SDK |
| `external` inventory | Direct or indirect Python, Swift, Rust, Kotlin, C++, Provider, packaged smoke, and manual probe entries |

## Routine Checks and Early Feedback

```bash
flutter pub get --enforce-lockfile
python .github/scripts/release_version.py --check
python .github/scripts/check_structure_imports.py
python .github/scripts/check_architecture_dependencies.py
python .github/scripts/test_suites.py --strict-imports --output build/test-audit/inventory.json
python .github/scripts/run_flutter_tests.py --partition fast --concurrency 4 --output build/test-audit/fast
python -m unittest discover -s .github/scripts/tests -p "test_*.py"
flutter analyze --no-pub --fatal-infos --fatal-warnings
git diff --check
```

Ownership checks cover new files, stale paths, Windows coverage, imports, external entries, platform skip declarations, and the complete partition union. New ordinary tests automatically enter the complete default partitions. Adding a file to fast requires reviewing native requirements, resource ownership, and measured cost. Fast results contribute to complete validation, which also needs the remaining applicable entries.

For targeted diagnosis, select owned files explicitly:

```bash
python .github/scripts/run_flutter_tests.py --output build/test-audit/reader-menu test/features/reader/reader_menu_integration_test.dart
```

The report records the actual selection. Complete CI compares the partition union with the manifest and rejects targeted reports as complete partitions. Complete profiles prohibit name, tag, and Flutter's built-in shard filters. Coverage mode also rejects arguments that reduce its coverage scope.

## Linux Full Suite and Native Libraries

Install CMake, Ninja, C/C++ tools, pkg-config, and the SQLite development library. On Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y cmake ninja-build g++ pkg-config libsqlite3-dev
RUSTFLAGS="--cfg reqwest_unstable" cargo test --locked --manifest-path packages/rhttp/rust/Cargo.toml --lib
RUSTFLAGS="--cfg reqwest_unstable" cargo build --locked --manifest-path packages/rhttp/rust/Cargo.toml --lib
mkdir -p build/test-native/lib
cp packages/rhttp/rust/target/debug/librhttp.so build/test-native/lib/librhttp.so
python .github/scripts/prepare_linux_test_libraries.py
export LD_LIBRARY_PATH="$(pwd)/build/test-native/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export VENERA_REQUIRE_NATIVE_TEST_LIBRARIES=1
python .github/scripts/run_flutter_tests.py --suite default --coverage --output build/test-audit/default
python .github/scripts/run_flutter_tests.py --suite tv --output build/test-audit/tv
```

The native preparer builds QuickJS, ZIP, and the Venera codec/archive library from the current package configuration, runs their ctest entries, and bundles the resolved `libsqlite3.so` with the current Rhttp library. All five files must exist and load. After downloading a CI bundle, `python .github/scripts/prepare_linux_test_libraries.py --verify-only` checks file hashes and loads the required libraries.

The quality workflow's `flutter-native` job still builds and executes ASan/UBSan and SAF descriptor regressions. See the [quality workflow](../../.github/workflows/analyze.yml) for the complete commands. Dart mocks cannot replace handle, ABI, or memory-safety evidence. Native code or security dependency changes require fresh builds and the applicable regressions.

## Windows and Other Platforms

Build a Debug bundle from the current Windows source, then configure its real path in PowerShell:

```powershell
flutter build windows --debug
$env:VENERA_NATIVE_TEST_DIRECTORY = (Resolve-Path 'build/windows/x64/runner/Debug').Path
$env:VENERA_REQUIRE_NATIVE_TEST_LIBRARIES = '1'
$env:Path = $env:VENERA_NATIVE_TEST_DIRECTORY + ';' + $env:Path
python .github/scripts/check_native_codec_bundle.py --platform windows --root build/windows/x64/runner/Debug
python .github/scripts/run_flutter_tests.py --suite windows --output build/test-audit/windows
cmake -S windows/tests -B build/windows/startup_tests -A x64
cmake --build build/windows/startup_tests --config Debug
ctest --test-dir build/windows/startup_tests -C Debug --output-on-failure
cmake -S packages/share_plus/windows/tests -B build/share-plus-tests -A x64
cmake --build build/share-plus-tests --config Debug
ctest --test-dir build/share-plus-tests -C Debug --output-on-failure
```

A Release bundle from current source is also supported. Fonts, Flutter DLLs, and real native libraries follow the selected bundle. CI sets `VENERA_REQUIRE_NATIVE_TEST_LIBRARIES=1` so missing dependencies fail. The runner resolves system temporary paths to their physical location while retaining the tests' internal alias and path-boundary checks.

| Independent entry | Command or maintenance location |
| --- | --- |
| Android JVM | Run `python .github/scripts/run_android_jvm_tests.py` on Linux with Java 17; verify official archive hashes, compiler versions, and actual main entries using the declared Kotlin 2.1.0 and share-package 2.2.0 profiles |
| Apple directory access | `swift test --package-path apple`; iOS Rhttp also has a separate native compatibility target check |
| Real Android Provider | Build/run the [isolated Provider tool](../../tool/saf_provider_probe/); quality CI executes persistent permission, 64-bit operations, and close protocols in an emulator |
| HarmonyOS scripts | `python -m unittest discover -s tool/harmonyos -p "test_*.py"` and `node --test tool/harmonyos/test_directory_bridge.mjs` |
| HarmonyOS host and HAP | [HarmonyOS Release Builds](harmonyos_releases.en.md), with fixed SDK, native libraries, controlled lockfile, and shared ownership |
| Devices and diagnostic probes | Follow the `external` manual entry and platform guide, recording original artifact, source commit, and actual outcome |

The macOS skip policy records explicit source-reviewed conditions; actual host execution is reported separately. Swift success, iOS compilation, Linux HarmonyOS host success, and HAP compilation retain distinct evidence. Device installation, upgrades, and real system interaction follow existing device acceptance requirements.

## CI Aggregation and Evidence

Quality CI runs fast, native preparation/sanitizers, three full partitions, and TV independently. Each full partition downloads the verified five-library bundle from the same workflow run and executes whole files. Matrix `fail-fast: false` preserves diagnostics from the remaining partitions. PR, main, complete-build, and release quality entries reuse the same complete guarantees; critical slow tests remain in those entries.

The stable gate remains `Flutter 测试与覆盖率`. Under `always()`, it requires every mandatory job to succeed, then checks actual machine reports for source commit, manifest byte SHA-256, partition ownership, the file union, case IDs/counts/terminal results, and skip reasons. Every requested LCOV must exist and match its hash. Failure, cancellation, unexpected skips, missing files, stale cases, or wrong compilation identity block success. TV's actual report lives separately under `tv` and does not enter the ordinary coverage denominator.

Report `source_commit` identifies the job's actual checkout, usually a temporary merge commit in PR checks. Record branch HEAD and executed checkout separately, and confirm comparable Git trees or file contents. These SHAs identify different commits and must not be silently substituted.

LCOV merges hits by normalized source path and line number, checking each record's LF/LH totals. Compare modules and critical paths under the same source and environment; there is currently no global percentage gate. Concatenating reports duplicates the denominator, so use the merger. Partition `events.jsonl`, `console.log`, `summary.json`, complete `aggregate/summary.json`, and final `dart-coverage` artifacts are retained for 14 days; keep decision summaries and CI links for long-term evidence.

`elapsed_ms` measures machine execution, `wall_seconds` measures the runner's elapsed time, and `suite_span_ms` includes file loading, scheduling, and test waits. Suites may overlap; their spans cannot be summed as job duration. Report preparation/build time, job duration, the complete PR critical path, and total Actions job execution separately, identifying cache, runner, and newly covered entries.

## Adding, Splitting, and Removing Tests

- Describe the independent behavior, starting state, operation, result, failure, and cleanup before selecting a layer and execution owner.
- New platform/native tests update ownership, native preparation, and applicable triggers together. Maintain inapplicable cases in `test/platform_skips.json` by OS, file, complete parameterized name, reason, and actual report evidence. Unprepared dependencies must fail.
- Extract helpers when multiple consumers have the same resource lifetime. Give each case independent temporary directories, databases, ports, and controls. Bounded waits need explicit conditions, timeouts, and propagated errors.
- Use roughly 1,000 lines as a prompt to review responsibilities. Split by behavior and resources while retaining traceable names. Code moved into support still counts toward total test size.
- Merges/removals record original cases/parameters, protected behavior, current-code evidence, replacements, platforms, and validation. Keep unresolved candidates. Names containing legacy, native, or integration do not determine removal.
- Preserve independent failure coverage for old databases/backups, transaction failure, real crash recovery, download resume/cancellation, path boundaries, FFI ownership, stale callbacks, menu locking, TV, and release provenance. Fixtures retain source, license, and hashes.
- Update `CHANGELOG.md` for each batch, use Chinese Conventional Commits, and finish local and complete CI validation before advancing. Roll back through normal batch reverts while retaining independent security fixes.
