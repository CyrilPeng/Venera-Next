# Local rhttp 0.15.1 patch

Source: the published `rhttp` 0.15.1 package from pub.dev, upstream repository
https://codeberg.org/Tienisto/rhttp. The upstream MIT license and the separate
Cargokit license are retained unchanged. The Dart bridge remains at 2.11.1;
Rust dependency security updates are recorded below. Example projects and
upstream Dart test fixtures are omitted; runtime,
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

Application-specific Rust source changes remain in `rust/src/api/http.rs`,
including its callback-drain tests and Rust formatting normalization. Other
local additions are this document, `.gitignore`, and `rust/cargokit.yaml`.
Apart from the Cargo.lock dependency updates below, all remaining retained
upstream files are byte-for-byte unchanged, including licenses, generated
bridge code and platform build entry points.

`git diff --check` reports inherited trailing spaces or final blank lines in
eight unchanged upstream files: `README.md`, `cargokit/LICENSE`,
`cargokit/README`, `cargokit/gradle/plugin.gradle`, the three generated
`lib/src/rust/api/{client,error,http}.freezed.dart` files, and
`rust/src/frb_generated.rs`. Their SHA-256 hashes were compared with upstream
and match byte-for-byte. They are retained as published; no repository
whitespace rule or formatting gate is disabled.

## Rust dependency security updates (2026-10-13)

The application pins Rust 1.92.0 in `rust-toolchain.toml` and the CI toolchain
preparation script. This satisfies the Rust 1.88 minimum required by the fixed
`time` release. Direct dependency declarations and generated bridge APIs remain
unchanged; the following Cargo.lock updates address the ten GitHub alerts and
additional findings from a complete RustSec scan:

| Crate | Previous | Updated | Security advisories |
|---|---|---|---|
| anyhow | 1.0.100 | 1.0.103 | RUSTSEC-2026-0190 |
| bytes | 1.11.0 | 1.11.1 | GHSA-434x-w66g-qw3r |
| h2 | 0.4.12 | 0.4.16 | RUSTSEC-2026-0258 |
| quinn-proto | 0.11.13 | 0.11.18 | GHSA-6xvm-j4wr-6v98, GHSA-4w2j-m93h-cj5j; RUSTSEC-2026-0338 through RUSTSEC-2026-0342 |
| rand | 0.9.2 | 0.10.3 | GHSA-cq8v-f236-94qc |
| rustls | 0.23.35 | 0.23.45 | GHSA-2mjx-qc3c-rqvc |
| rustls-webpki | 0.103.8 | 0.103.15 | GHSA-pwjx-qhcg-rvj4, GHSA-965h-392x-2mh5, GHSA-xgp8-3hg3-c2mh, GHSA-82j2-j2ch-gfr8 |
| time | 0.3.44 | 0.3.47 | GHSA-r6v5-fh4h-64xc |

The `time` update also requires `num-conv` 0.2.2, `time-core` 0.1.8 and
`time-macros` 0.2.27. Existing `serde_core` replaces `serde` on that dependency
edge. Updating `quinn-proto` to 0.11.18 replaces its Rand 0.9 dependency graph
with Rand 0.10: `rand_core` 0.10.1, `rand_pcg` 0.10.2, `chacha20` 0.10.2,
`cpufeatures` 0.3.1 and `getrandom` 0.4.3 (with `r-efi` 6.0.0). The older
`rand_chacha`, `ppv-lite86`, `zerocopy`, `zerocopy-derive`, `wasip2` and
`wit-bindgen` entries are no longer needed. The separate `getrandom` 0.2.16
entry remains unchanged. No unrelated dependency versions are downgraded.

Dependabot checks this Rust package weekly while keeping Flutter Rust Bridge
updates separate from its generated Dart code. The dependency security workflow
runs cargo-audit 0.22.2 against the complete lockfile on pull requests, pushes to
main, manual dispatch and a weekly schedule. It fetches current RustSec
advisories and fails on known vulnerabilities and unsoundness warnings without
advisory exclusions.

## Routine Rust dependency updates (2026-10-13)

Dependabot PR #101 updates Chrono 0.4.42 to 0.4.45, Futures crates 0.3.31
to 0.3.34, Tokio 1.48.0 to 1.53.2, and Tokio-util 0.7.17 to 0.7.20. Their
transitive lockfile changes update libc, Mio, socket2 and Tokio macros, and
add Syn 3 alongside the retained Syn 2 dependency graph. These are compatible
with the existing manifest constraints and Rust 1.92.0 toolchain. Generated
bridge code, the exact Flutter Rust Bridge 2.11.1 pin, callback-drain patch,
and the security-fixed crate entries above remain unchanged.

Dependabot PR #102 updates Reqwest 0.12.25 to 0.12.28 and cookie_store 0.21.1
to 0.22.1 in the same lockfile. HTTP settings, streaming cancellation and
callback acknowledgment handling remain unchanged. The two routine updates
are combined without reverting any of the security fixes listed above.

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
included Cargokit builder on native platform builds. Native Flutter regressions
must load a newly compiled library from this source, not an older DLL left in
the app output.
