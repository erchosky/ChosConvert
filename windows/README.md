# ChosConvert for Windows — not started (Phase 5)

Per the build plan, Windows work starts after the shared core and the macOS MVP are solid.
Already shared and ready: the Rust core (`core/`, builds as `chosconvert_ffi.dll` via the
`cdylib` crate type), the JSON/C ABI (`core/include/chosconvert_core.h`), fixtures, error codes,
plan steps and notes. CI already builds and tests the core on `windows-latest`.

Planned stack: C# / .NET (current LTS), WinUI 3 on the stable Windows App SDK, MVVM,
`LibraryImport` P/Invoke to the core, WIC + Media Foundation as native engines, MSIX packaging.
The UI will follow Windows 11 design (Fluent), not a port of the SwiftUI screens.
