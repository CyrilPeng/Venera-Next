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

## Translation Contributions

The app currently supports Simplified Chinese, Traditional Chinese, English, German and Japanese. Submit corrections to existing translations directly as a PR, identifying the screen, source text and intended meaning. English source text is also the translation key, so changes must update all language dictionaries. See [Translation Maintenance](doc/development/build.en.md#translation-maintenance) for files, placeholder rules, the glossary and audit commands.

Propose a new language through the [feature request form](https://github.com/CyrilPeng/Venera-Next/issues/new?template=06-enhancement.yaml), or add information to an existing request for that language. Include the following in the use case and proposed solution:

- The language, region and intended identifier, such as a BCP 47 tag; explain differences between regional variants.
- Evidence of demand, primary platforms and the features people use most.
- Whether you can translate, independently review or maintain the language, and the scope you can cover.
- Public translations or terminology references, if available; state when references or reviewers are missing.

German and Japanese are the first additions. Readers familiar with either language are welcome to provide native-language review and ongoing maintenance. Critical action meanings have been checked against the source text, but no community native-language reviewer has participated yet. Future languages will be selected based on demand and review capacity before accepting new dictionaries. Machine translation can provide a draft. A reviewer familiar with the language must check the affected data, consequences and actions in deletion, overwrite, backup/restore and error messages. Drafts may arrive in batches; language selection is enabled after dictionaries and acceptance checks are complete.

Translation PRs identify the source commit, completed and reviewed scope, reviewers, and results for language switching, English fallback, phone/desktop layouts and large text. Build test packages through GitHub Actions from the corresponding commit and link the run; linguistic and layout feedback must refer to the same text revision. Comic-source script translations belong to their respective maintainers, and translating the app interface does not translate source-site content.

## Development Requirements

Use the repository's Flutter version and resolve dependencies from the lock file:

```bash
flutter pub get --enforce-lockfile
```

Follow [Running and Maintaining Tests](doc/development/testing.en.md) to prepare native libraries on the applicable host, run the complete ownership manifest, and read CI evidence. New platform/native cases update their execution owner and reviewed skip declarations; merges/removals identify replacement coverage.

Run at least these checks before submitting:

```bash
python .github/scripts/release_version.py --check
python .github/scripts/check_structure_imports.py
python .github/scripts/check_architecture_dependencies.py
python .github/scripts/test_suites.py --strict-imports --output build/test-audit/inventory.json
python -m unittest discover -s .github/scripts/tests -p "test_*.py"
flutter analyze --no-pub --fatal-infos --fatal-warnings
python .github/scripts/run_flutter_tests.py --suite default --coverage --output build/test-audit/default
git diff --check
```

For changes limited to Issue forms, Python automation and related documentation, run the Python tests, version/structure checks and `git diff --check` locally. The existing PR quality workflow verifies Flutter analysis, the complete test suite and platform gates.

New dependencies must document their source, version or commit, rationale, license, upstream status, and alternatives. Do not add `any` dependencies or unfixed Git branches. See [Dependency Governance](doc/development/dependencies.en.md).

Keep commits focused and use `<type>(<scope>): <Chinese description>` Conventional Commits messages. Update `CHANGELOG.md` before committing to describe the completed behavior or repository-maintenance changes in that batch.

## Pull Requests

Describe the problem, approach, affected areas, test commands, and unverified platforms. Data migrations, release changes, and dependency upgrades must include a rollback path.

Do not create public Issues for security vulnerabilities. See the [Security Policy](SECURITY.md) and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
