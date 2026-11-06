# VeneraNext native codecs

This private application package provides `encodePngRgba` and
`extractSevenZip`. Its Dart API, C ABI and platform build integration were
written for VeneraNext and use GPL-3.0-or-later, as does the application.

The native algorithms retain separately licensed official source:

- LodePNG 20241015, copyright Lode Vandevenne, Zlib license.
- The retained 7-Zip 24.09 C decoder files, authored by Igor Pavlov and expressly
  placed in the public domain in their source headers. Other parts of the
  7-Zip repository are not included or assigned this licensing status.

`SOURCE_MANIFEST.json` distinguishes project-authored files from third-party
files and records both their official source blobs and local checksums.
`LOCAL_PATCHES.md` records the migration, validation and rollback procedure.
The original native source notices remain in `third_party/`; distribution
notices are bundled with the application on supported platforms.

PNG input is straight RGBA with exactly four bytes per pixel. The function
returns an independent Dart byte array and releases native allocations on
success or error. It does not expose a pointer-backed result to callers.

7z extraction runs in an isolate, owns and closes one archive, and reuses the
decoder's solid-block cache. It verifies decoded data and checks all archive
names before writing. Absolute paths, traversal, conflicting entries and
symbolic links are rejected. This C decoder supports 7z/CB7; the application's
existing ZIP and Dart ZIP fallback paths remain separate. Password-protected
archives and unsupported 7z compression methods report errors.
