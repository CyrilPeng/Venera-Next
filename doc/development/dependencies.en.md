# Dependency Governance

Default Chinese version: [dependencies.zh.md](dependencies.zh.md)

This document records governance rules for VeneraNext's direct dependencies, especially Git dependencies that are not resolved from pub.dev. `pubspec.lock` is part of reproducible builds, but it does not replace documenting dependency provenance and maintenance responsibility.

## Rules

- Commit related changes to both `pubspec.yaml` and `pubspec.lock`.
- Prefer stable pub.dev packages. Every Git fork must have a documented reason.
- Pin Git dependencies to immutable commits. Do not use a default branch, `main`, or `HEAD`.
- Tools installed with `dart pub global activate` in release workflows must use the same pinned commit.
- Review upstream changes, security advisories, licenses, platform builds, and relevant tests when upgrading.
- Publishing a fork to pub.dev does not replace security maintenance; a diff audit and upstream synchronization plan are still required.

## Current Git Dependencies

| Dependency | Commit | Upstream / license | Immediate reason for retaining the customized repository |
|---|---|---|---|
| `flutter_qjs` | `8feae95df7fb00455df129ad7a0dfec1d0e8d8e4` | Fork upstream not recorded / MIT | The pinned revision includes NDK r28 build support; replacement requires JavaScript runtime and native platform build verification |
| `photo_view` | `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c` | Fork upstream not recorded / MIT | The pinned revision changes position adjustment in `PhotoViewCoreState`; reader zoom and gestures rely on that behavior |
| `scrollable_positioned_list` | `09e756b1f1b04e6298318d99ec20a787fb360f59` | `google/flutter.widgets` / BSD-3-Clause | The pinned revision adds `scrollControllerCallback` and `scrollBehavior`, used by continuous-reader positioning |
| `desktop_webview_window` | `7801fc582ecf5a7351632887891ecf309a7b2583` | `wgh136/flutter_desktop_webview` / not declared | The pinned revision fixes Windows ARM64 builds; replacement requires verification on every desktop platform |
| `flutter_inappwebview` | `3ef899b3db57c911b080979f1392253b835f98ab` | `pichillilorenzo/flutter_inappwebview` / Apache-2.0 | The pinned revision fixes `GraphicsContext` deallocation; embedded WebView and Cloudflare flows rely on this branch behavior |
| `lodepng_flutter` | `ac7d05dde32e8d728102a9ff66e6b55f05d94ba1` | Fork upstream not recorded / license file is still a placeholder | The pinned revision includes NDK r28 build support, and the image pipeline still uses its native plugin |
| `webdav_client` | `2f669c98fb81cff1c64fee93466a1475c77e4273` | `wgh136/webdav_client` / BSD-3-Clause | The pinned revision adds multiple authentication methods required by WebDAV reading and backup compatibility |
| `flutter_saf` | `fe182cdf40e5fa6230f451bc1d643b860f610d13` | `pkuislm/flutter_saf` / license file is still a placeholder | The pinned revision disables minification to avoid Android release-build problems; storage access still uses this plugin |
| `flutter_7zip` | `b33344797f1d2469339e0e1b75f5f954f1da224c` | `wgh136/flutter_7zip` / license file is still a placeholder | The pinned revision fixes compilation errors, and CBZ/archive fallback compatibility still uses this plugin |
| `flutter_to_debian` | `3777c91b6b1cc0b7c03357c67ca216d4313c3db5` | `jeffrey0606/flutter_to_debian` / MIT | The pinned revision fixes propagation of Debian `Depends`; it is used only for Linux packaging |

The table uses commit messages to explain why the project cannot immediately switch back to upstream. It is not a complete diff audit. Every Git dependency update must document the upstream repository, comparison range, all custom changes, upstream PR if any, security impact, and rollback path.

`desktop_webview_window` does not declare a license, while `lodepng_flutter`, `flutter_saf`, and `flutter_7zip` still contain placeholder license files. These are known supply-chain debts. Confirm licensing with the maintainers before upgrading; if it cannot be confirmed, migrate to an upstream revision or replacement with clear licensing.

## Upstreaming Process

1. Compare the pinned commit with the corresponding upstream version.
2. Submit generic changes upstream as focused pull requests.
3. Document and test changes that cannot be upstreamed.
4. Update the fork after upstream security fixes, then update this repository's pinned commit.
5. Record risks for abandoned dependencies that cannot yet be replaced; never silently switch to a floating branch.

## Review Checklist

- [ ] `pubspec.yaml` uses immutable commits, never `HEAD` or a default branch.
- [ ] Resolved commits in `pubspec.lock` match the declarations.
- [ ] Release workflows use the same commit for Git-installed tools.
- [ ] `flutter pub get --enforce-lockfile`, `flutter analyze --no-pub`, and `flutter test --no-pub` have passed.
- [ ] Platform builds have passed, or unverified platforms are documented.
- [ ] Licenses, security advisories, and upstream changes have been reviewed.
