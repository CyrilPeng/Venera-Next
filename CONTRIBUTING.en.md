# Contributing

Default Chinese version: [CONTRIBUTING.md](CONTRIBUTING.md)

Thank you for your interest in VeneraNext. This repository maintains the reader itself. It does not provide, maintain, or troubleshoot comic sources.

## What to Submit

- Reader defects reproducible without a specific source site or title.
- Improvements to reading modes, local comics, WebDAV, archives, sync, settings, platform builds, and documentation.
- Feature proposals with a clear use case, implementation boundary, and verification approach.

## What Not to Submit

Do not report source-site content, search results, title availability, missing chapters, image availability, or copyright issues. Report those to the relevant extension, source site, or network provider.

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

New dependencies must document their source, version or commit, rationale, license, upstream status, and alternatives. Do not add `any` dependencies or unfixed Git branches. See [Dependency Governance](doc/development/dependencies.en.md).

Keep commits focused, use concise Conventional Commits-style messages, and update `CHANGELOG.md` for user-visible or repository-maintenance changes.

## Pull Requests

Describe the problem, approach, affected areas, test commands, and unverified platforms. Data migrations, release changes, and dependency upgrades must include a rollback path.

Do not create public Issues for security vulnerabilities. See the [Security Policy](SECURITY.md) and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
