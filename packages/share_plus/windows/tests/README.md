# Windows native share regression tests

Configure and run from the application repository, using a Visual Studio C++
toolchain and Windows SDK. The Flutter Windows wrapper headers must already exist
(a normal Flutter Windows configuration creates them).

```powershell
cmake -S packages/share_plus/windows/tests -B <external-build-directory> -A x64 `
  -DFLUTTER_EPHEMERAL_DIR="<repository>/windows/flutter/ephemeral"
cmake --build <external-build-directory> --config Debug
ctest --test-dir <external-build-directory> -C Debug --output-on-failure
```

The standalone project compiles the production `share_request.cpp` and the actual
plugin adapter (as an object target, without loading/replacing an app DLL).
`share_request_test` runs six regression groups. It uses real WinRT DataPackage,
StandardDataFormats, StorageFile and temporary files; fake COM event managers
allow deterministic delayed callbacks and registration/removal failures. A
reference-counted item checks the production storage collection's ownership and
partial-resolution cleanup. The tests open no share UI.

Covered behavior includes file → text → file isolation, callbacks retained after
replacement/destruction, 100 replacements with one live subscription, original
HRESULTs, show/cleanup double failure, DataRequest failure reporting, malformed
arguments, missing real files and native collection lifetime.

Replacement failure also covers an acknowledged first panel whose DataRequested
has not fired: after the next Show fails, invoking the manager's current handler
still provides the first payload, with at most one subscription. A failed new
registration restores the old handler, while a failed restoration preserves both
HRESULTs. Synchronous callbacks inside successful/failed Show and a concurrent
GetDeferral spanning Show's return verify that data is chosen only after the Show
outcome. Deferrals complete once, including rejected/failed data. With no prior
request, Show failure rejects pending data and removes the new registration.

The plugin still returns `ShareResult.unavailable` after ShowShareUIForWindow
succeeds. It does not claim the receiver finished reading a source file and does
not delete shared sources. The Windows documentation describes:

- [DataRequested](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.datatransfer.datatransfermanager.datarequested): occurs when a share operation starts; the callback provides data.
- [TargetApplicationChosen](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.datatransfer.datatransfermanager.targetapplicationchosen): records which target the user chose, not completion of its file consumption.

These tests validate production data/COM logic, not the OS share panel or an
external application's consumption lifetime. Interactive receiver compatibility
remains a native/manual verification step.
