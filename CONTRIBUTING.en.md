# Contributing

Default Chinese version: [CONTRIBUTING.md](CONTRIBUTING.md)

Thank you for your interest in VeneraNext. This repository maintains the reader itself. It does not provide, maintain, or troubleshoot comic sources.

## What to Submit

- Reader defects reproducible without a specific source site or title.
- Improvements to reading modes, local comics, WebDAV, archives, sync, settings, platform builds, and documentation.
- Feature proposals with a clear use case, implementation boundary, and verification approach.

## What Not to Submit

Do not report source-site content, search results, title availability, missing chapters, image availability, or copyright issues. Report those to the relevant extension, source site, or network provider.

## Submitting Issues

Use the [categorized forms](https://github.com/CyrilPeng/Venera-Next/issues/new/choose) for crashes, reader performance, local data, network/WebDAV, UI/interaction or features. Report one independent problem per Issue and describe a trigger and symptom in the title.

Crashes, import/data defects and network failures need redacted logs; reader performance needs manual Reading diagnostics. UI reports and feature requests do not require logs. Explain unavailable diagnostics and provide alternative evidence. Deterministic checks update the same comment when missing information is supplied; they do not close Issues or impose new forms on historical reports. See the [reporting guide](doc/user/issue_reporting.en.md).

## Development Requirements

Use the repository's Flutter version and resolve dependencies from the lock file:

```bash
flutter pub get --enforce-lockfile
```

Run at least these checks before submitting:

```bash
python .github/scripts/check_structure_imports.py
python -m unittest discover -s .github/scripts/tests -p "test_*.py"
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

For changes limited to Issue forms, Python automation and related documentation, run the Python tests, version/structure checks and `git diff --check` locally. The existing PR quality workflow verifies Flutter analysis, the complete test suite and platform gates.

New dependencies must document their source, version or commit, rationale, license, upstream status, and alternatives. Do not add `any` dependencies or unfixed Git branches. See [Dependency Governance](doc/development/dependencies.en.md).

Keep commits focused, use concise Conventional Commits-style messages, and update `CHANGELOG.md` for user-visible or repository-maintenance changes.

## Pull Requests

Describe the problem, approach, affected areas, test commands, and unverified platforms. Data migrations, release changes, and dependency upgrades must include a rollback path.

Do not create public Issues for security vulnerabilities. See the [Security Policy](SECURITY.md) and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
