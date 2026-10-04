# Local rhttp 0.15.1 patch

Source: the published `rhttp` 0.15.1 package from pub.dev, upstream repository
https://codeberg.org/Tienisto/rhttp. The upstream MIT license and the separate
Cargokit license are retained unchanged. No Dart or Rust dependency versions are
upgraded. Example projects and upstream Dart test fixtures are omitted; runtime,
generated bridge, Rust sources, Cargo.lock and all five native platform build
integrations are retained.

Original pub archive SHA-256:
`b111638045b730f825a85cb045017b5bd3dfb47b38e98eb293b0519ee6050f2e`.

## Cancellation-safe streaming callbacks

In `rust/src/api/http.rs`, `make_http_request_receive_stream` previously dropped
an in-flight `on_response` or inner `on_error` Dart callback when its
`tokio::select!` cancellation branch won. Flutter Rust Bridge 2.11.1 then panicked
at `dart_fn/handler.rs` when Dart delivered the callback result to the dropped
oneshot receiver. rhttp builds with `panic = "abort"`, so this terminated the
process.

`CallbackDrain` retains shared callback futures. Cancellation still drops the
HTTP request/body immediately, and the enclosing native call joins callback
acknowledgments before it returns. It does not spawn workers, buffer the HTTP
response, delay cancellation with a timer, or change the response/error types.
Deterministic Rust tests hold acknowledgment channels across cancellation and
verify that native completion waits for all callbacks.

The app's `rhttp_stream_request.dart` separately retains the generated bridge's
`executeNormal` Future. Dart stream `onDone` alone is insufficient: FRB may close
its Dart stream after a decoding error while Rust is still finishing a callback.

## Formatting normalization

The repository's existing new-file formatting check also applies to vendored
Dart files. Fifteen files under `cargokit/build_tool/lib/src/` were normalized
with the existing Dart 3.11.4 formatter:

- `android_environment.dart`, `artifacts_provider.dart`, `build_cmake.dart`
- `build_gradle.dart`, `build_pod.dart`, `build_tool.dart`, `builder.dart`
- `crate_hash.dart`, `logging.dart`, `options.dart`, `precompile_binaries.dart`
- `rustup.dart`, `target.dart`, `util.dart`, `verify_binaries.dart`

These changes are formatting only. Separately copied upstream and vendored
versions of all fifteen files were formatted with that same formatter outside
the repository; each pair produced identical SHA-256 hashes. The pub cache was
not modified. No formatting exclusions or changes to the check were added.

The only upstream file with behavior changes remains `rust/src/api/http.rs`,
including its callback-drain tests and Rust formatting normalization. Other
local additions are this document, `.gitignore`, and `rust/cargokit.yaml`.
All remaining retained upstream files are byte-for-byte unchanged, including
licenses, Cargo.lock, generated bridge code and platform build entry points.

`git diff --check` reports inherited trailing spaces or final blank lines in
eight unchanged upstream files: `README.md`, `cargokit/LICENSE`,
`cargokit/README`, `cargokit/gradle/plugin.gradle`, the three generated
`lib/src/rust/api/{client,error,http}.freezed.dart` files, and
`rust/src/frb_generated.rs`. Their SHA-256 hashes were compared with upstream
and match byte-for-byte. They are retained as published; no repository
whitespace rule or formatting gate is disabled.

## Building the patched source

Windows/Linux CMake, Android Gradle and iOS/macOS pod scripts all invoke the
included Cargokit against `../rust`. `rust/cargokit.yaml` deliberately contains
no `precompiled_binaries`. Cargokit's `ArtifactProvider` therefore returns no
prebuilt artifacts and compiles this source, even if the user enables prebuilt
binaries globally. Do not add an upstream prebuilt URL: those libraries lack
this patch. The normal platform Rust toolchain/SDK remains required.

Use `cargo test --locked --manifest-path packages/rhttp/rust/Cargo.toml --lib`
with `RUSTFLAGS="--cfg reqwest_unstable"` for the callback regressions. This flag
is required by the existing reqwest HTTP/3 feature and is already set by the
included Cargokit builder on native platform builds. Native Flutter regressions must load a newly
compiled library from this source, not an older DLL left in the app output.
