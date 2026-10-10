# Public-symbol candidate inventory

This is an isolated maintenance package, not an application dependency. Run from
this directory after resolving its pinned lockfile:

```text
dart pub get --enforce-lockfile
dart run bin/self_check.dart
dart run bin/public_symbols.dart ../.. ../../output/public-symbols.json
dart analyze --fatal-infos
```

Create the output directory first if it does not exist. The lockfile uses
`https://pub.dev`; if a local `PUB_HOSTED_URL` selects a mirror, set it to
`https://pub.dev` for locked resolution. A proxy may be used for connectivity.

The tool reads tracked working-tree Dart files under `lib/` and `test/`, parses
declarations and counts identifier tokens by name. It does not resolve calls or
prove that a declaration is dead. Same-name declarations/references can hide
candidates. Overrides, operators, implicit extension lookup, runtime entrypoints,
JS/native protocols and test-only APIs require manual review. Private names,
parameters, unnamed constructors and local functions are not independent public
candidates. Public-name members of private owners are included.

The self-check covers declaration kinds, local/private exclusions, annotations,
string evidence and duplicate visits. CI prepares this package before repository
analysis. Raw output is diagnostic evidence only; it is not a committed dead-code
decision and does not replace manual review of framework, native, JavaScript, or
test entry points.
