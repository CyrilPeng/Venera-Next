# venera_native 1.0.0 maintenance

This is project-authored application code, pinned by the VeneraNext application
commit. It is not a snapshot of either old Flutter wrapper. The public Dart
API, FFI bindings, ownership checks, archive path validation and platform build
files were written for this repository under GPL-3.0-or-later.

## Separately retained native cores

LodePNG 20241015 comes from https://github.com/lvandeve/lodepng at
`79a61c79cc62814f315661f53a026004bac80614`. Its `lodepng.cpp` is renamed to
`lodepng.c` for C compilation without editing the algorithm. `LICENSE` is an
excerpt of the same file's original Zlib notice; the complete notices remain
in both source files. The previous fixed plugin's C implementation differs
only by its appended `freePtr` function; its header added export annotations.
This package exports its own ABI without changing the official header.

The retained C decoder subset comes from https://github.com/ip7z/7zip at the
24.09 tag's commit `e5431fa6f5505e385c6f9367260717e9c47dc2ee`. The 34 runtime
C/header files match the former fixed plugin byte for byte after canonical LF
normalization. The additional official `7zVersion.h` records Igor Pavlov's
public-domain declaration. Only this expressly public-domain subset is
retained; this is not a license claim about the entire 7-Zip repository.

CI UBSan identified undefined unaligned integer accesses in `CpuArch.h`,
including the 7z start-header's 64-bit values at byte offsets 12 and 20.
One project macro guard, `VENERA_LZMA_PORTABLE_ENDIAN`, now selects the core's
existing byte-wise endian helpers on every platform. CMake and both Apple pods
define this flag. The official source hash remains recorded separately from
the patched local hash; the core's original public-domain notice is retained.
Alignment sanitizers remain enabled. Android smoke builds target all three
ABIs configured by the app's split APK build, so every checked APK contains
matching Flutter and codec libraries.

`SOURCE_MANIFEST.json` labels project files as `project`, and third-party files
with their separate source IDs and original relative filenames. Third-party
licenses, complete directory inventories and local file hashes are checked by
the dependency inventory tool. For a license excerpt or filename rename,
the original Git blob hash and the local hash intentionally differ or refer
to the original name. No old Dart wrapper or unlicensed build glue is retained.

The package requires Dart 3.8 / Flutter 3.32 APIs, allowing the existing separate
Harmony SDK to keep its version. Android stages CMake output in the application's
build directory, keeping generated `.cxx` files out of reviewed source. Apple
pods use small project-authored `Classes/` adapters to include the common native
translation units; license and notice copies stay inside each pod's source root.

## API and ownership

PNG validates dimensions and exact byte length in Dart and the native ABI,
checks encoder status and copies output before freeing it. Its native failure
paths clear both the output pointer and size. Typed views retain their offsets,
and RGBA/alpha and compression settings retain the existing algorithm.

The 7z bridge initializes all stream and database state before a possible
failure, closes every partial open, serializes process-wide CRC initialization,
and validates indices and decoded lengths. Windows archive paths use UTF-8 to
wide-character conversion. Native decoded blocks remain owned by the archive;
the synchronous writer consumes each view before another read or close.
Missing filename metadata fails before entering the old core's filename reader,
with an independent archive fixture covering this failure.

One worker reuses a solid-block cache across files rather than repeatedly
decoding a solid archive in four independent workers. Every entry is preflighted
for traversal, absolute names, collisions, file parents and link attributes;
case collisions are also rejected on Windows and macOS, and existing output
links are rejected. The application retains its existing
ZIP → 7z → Dart ZIP error fallback and 7z/CB7 import capabilities.

## Validation and changes

Run strict Flutter analysis, inventory and structure checks, native ABI tests,
PNG round-trip/view/alpha regressions, real solid/non-solid/Unicode/empty-file
7z extraction and malformed/archive-path regressions. Use independent 7z
fixtures and compare PNG timings and RSS against the previous fixed library.
Full Android, Windows, Linux and Apple builds verify platform glue.

On 2026-11-06, local Flutter 3.41.6 / Dart 3.11.4 strict analysis, enforced
lockfile resolution, dependency/architecture checks and Windows x64 Debug
application build passed. The focused seven-file Flutter run passed 124 tests,
with two platform-link cases skipped on Windows; 230 Python tests passed with
seven platform-only skips. The standalone Release C ABI regression passed
100 repeated ownership/error cycles, including invalid dimensions, missing
filename metadata, CRC errors and failed opens. CI supplies the other complete
platform builds and Linux ASan/UBSan verification; local results alone do not
establish those platform results.

The controlled Release-library old/new/old PNG probe used 1600×2400 straight
RGBA, one warm-up per phase and five timed runs, measuring native encode,
owned output copy and release. Old and new encoded bytes were identical for
both synthetic inputs:

| Input | Old A1 median | New B median | Old A2 median | Encoded bytes |
|---|---|---|---|---|
| Monochrome | 168.98 ms | 171.43 ms | 172.35 ms | 2,201 |
| Color | 528.98 ms | 521.07 ms | 524.98 ms | 127,967 |

The new timings stay within or close to baseline variation. Sampled process
RSS was about 39–41 MiB; process peaks were cumulative within this single
process and cannot identify independent per-encode peaks. This verifies host
native encoding compatibility, not Android frame stalls or energy use, and
does not close the reader-performance issue. Reproduce with
`python tool/native_png_probe.py --old-library <baseline> --new-library <candidate> --output <report>`.

The official 7-Zip changelog was reviewed through 26.05 at
`b88c6bc09339de32f7d18bbab900686b244f42ba`. The compiled subset does not include
XZ or the other archive handlers/C++ link-extraction paths named by later
advisories. LZMA2 decoder files are unchanged; the LZMA decoder diff uses
equivalent temporary expressions. The newer 7z header parser also adds count,
duplicate-property and bounds hardening. This source migration retains 24.09;
a core update must separately review those parser changes and hostile-header
regressions. This is not a complete security audit of every possible archive.

For changes, review official upstream fixes, update the source IDs/checksums
when changing native algorithms, and update local hashes, this record and the
application CHANGELOG before committing. Do not edit shared Pub caches.

Rollback restores both original Git declarations, their locked records,
dependency inventory and application imports together, and reruns encoding
and archive regressions. The historical fixed forks remain for old builds.
