# LibreOffice WASM diagnostic builder

An isolated, reproducible GitHub Actions project for compiling one diagnostic
LibreOffice WASM runtime. The current build is intentionally pinned to the
Matbee package-classic `importScripts(soffice.js)` shape and the `load-v4`
native marker set so it can locate the deepest active browser `documentLoad`
scope. It is not a production LibreOffice fork or a runtime distribution
repository.

## Pinned inputs

- LibreOffice branch: `libreoffice-24-8`
- LibreOffice commit: `d1c9e0e4e1ddeb24fe8f93e56860b3765043f8b1`
- Emscripten SDK: `3.1.74`
- Diagnostic glue mode: `package-classic`
- Diagnostic marker set: `load-v4`
- WASM compatibility patch: `patches/wasm-build-fixes.patch`
- Package-classic glue patch: `patches/package-classic-glue.patch`
- Native document-load trace patch: `patches/libreoffice-24-8-document-load-native-markers.patch`

`build.env` records SHA-256 values for every local build input. The build fails
before cloning or compiling if one of those files has changed unexpectedly.

## Why the workflow builds natively

The GitHub runner invokes Emscripten directly. It deliberately does not build a
Docker image, create nested Docker volumes, or copy a LibreOffice source tree
into a Docker volume. This removes the local tarball-volume ownership failure
and avoids spending runner disk on Docker image layers.

## Trigger a build

The workflow is manual-only so an expensive build cannot start on every push or
pull request.

1. Open **Actions**.
2. Select **Build LibreOffice WASM diagnostic**.
3. Choose **Run workflow**.
4. Leave `runner_label=ubuntu-24.04` for the first attempt.
5. Set `build_jobs` to `4` for a public standard runner or `2` for a smaller
   runner. The script also caps jobs using detected CPU and available memory.

If the standard runner runs out of disk or memory, rerun with an available
larger-runner label. The label is intentionally an input because larger-runner
names are configured by the owning GitHub organization.

## Outputs

The build emits classic `soffice.js` glue compatible with Matbee's dedicated
Worker `importScripts` path. The collect step also creates Node-oriented `.cjs`
copies without changing the browser artifact contract.

A successful run uploads a seven-day artifact containing:

```text
soffice.wasm
soffice.data
soffice.js
soffice.cjs
soffice.worker.js       # when emitted by LibreOffice
soffice.worker.cjs      # when emitted by LibreOffice
SHA256SUMS
BUILD-METADATA.txt
```

Logs are uploaded separately for fourteen days even when configure or make
fails. They include `build.log`, `config.log`, source revision, ccache stats,
and runner disk usage when available.

Before publishing, the build verifies that the final glue is not ES6, that
`soffice.wasm` contains `LOK_LOAD_TRACE` and every required `load-v4` boundary,
and that it does not contain `LOK_SAVEAS_TRACE`. `BUILD-METADATA.txt` records
`package-classic`, `load-v4`, and the pinned patch hashes.

## Cache policy

The workflow caches only:

- Emscripten SDK files;
- LibreOffice external source tarballs;
- up to 4 GiB of ccache objects.

It does not cache the complete LibreOffice source tree or `workdir`. Cache keys
include the pinned commit and patch hashes so incompatible compiler objects are
not reused.

## Diagnostic use

Do not overwrite production or content-addressed LibreOffice assets. Download
the workflow artifact and connect it to an isolated browser route or harness.
Run exactly one known-hanging DOCX and collect Worker console lines containing:

```text
[LOK_LOAD_TRACE]
```

Function- and block-lifetime boundaries use RAII scopes. The two
construction-only regions (`SfxModelGuard` and `SwWrtShell`) use paired explicit
entry/exit emits so the marker lifetime does not extend beyond the intended
construction. The marker set brackets only top-level functions or single
O(1)-per-load calls; it deliberately excludes DomainMapper per-element
probes, wait/yield/lock speculation, document content, URLs, filenames, filter
options, UNO payloads, and save/export markers.

The ordered boundaries are:

1. `lo_documentLoadWithOptions`
2. `SolarMutexGuard`
3. `frame::Desktop::create`
4. outer LOK call site `loadComponentFromURL`
5. `LoadEnv::loadComponentFromURL`
6. `LoadEnv::impl_detectTypeAndFilter`
7. `SfxFrameLoader_Impl::load`
8. `SfxBaseModel::load`
9. `SfxObjectShell::DoLoad`
10. `SfxObjectShell::ImportFrom`
11. `WriterFilter::filter`
12. `WriterFilter::OOXMLDocument::resolve`
13. `WriterFilter::pStream.clear`
14. `SfxFrameLoader_Impl::impl_createDocumentView`
15. `SfxBaseModel::createViewController`
16. `SfxBaseModel::SfxModelGuard`
17. `SfxBaseModel::FindOrCreateViewFrame_Impl`
18. `SfxFrame::Create`
19. `SfxFrame::PrepareForDoc_Impl`
20. `SfxViewFrame::SfxViewFrame`
21. `SfxViewFactory::CreateInstance`
22. `SwView::SwWrtShell`
23. `utl::ConnectFrameControllerModel`
24. `utl::ConnectModelController`
25. `XFrame::setComponent`
26. `SfxBaseController::attachFrame`
27. `SfxBaseController::ConnectSfxFrame_Impl`
28. `ConnectSfxFrame::EnableViewFrame`
29. `ConnectSfxFrame::UnlockDispatcher`
30. `ConnectSfxFrame::PushViewShell`
31. `ConnectSfxFrame::PushSubShells`
32. `ConnectSfxFrame::FlushDispatcher`
33. `ConnectSfxFrame::ShowEditWindow`
34. `ConnectSfxFrame::UpdateCurrentDispatcher`
35. `ConnectSfxFrame::ShowPreActivationFrameWindow`
36. `ConnectSfxFrame::GetPluginMode`
37. `ConnectSfxFrame::VisibleFrameSetup`
38. `ConnectSfxFrame::HiddenFrameWindowShow`
39. `ConnectSfxFrame::UpdateTitle`
40. `ConnectSfxFrame::ResizeViewFrame`
41. `ConnectSfxFrame::GetCreationArguments`
42. `ConnectSfxFrame::ApplyRecentDocsPolicy`
43. `ConnectSfxFrame::JumpToMark`
44. `ConnectSfxFrame::GetViewData`
45. `ConnectSfxFrame::ReadUserDataSequence`
46. `ConnectSfxFrame::InvalidateViewBinding`
47. `LibLODocument_Impl`

Use the deepest boundary with an `entry` and no matching `exit` only as a scope
localizer:

| Last completed / first missing return | Evidence-supported scope |
| --- | --- |
| Outer call entered; `LoadEnv::loadComponentFromURL` absent | dispatch, UNO, or generated-glue gap before the implementation body |
| `LoadEnv::loadComponentFromURL` entered; detection absent | `LoadEnv` setup or pre-detection path |
| detection entered without exit | type/filter detection |
| detection exited; frame loader absent | content handling, frame creation, loader lookup, or synchronous dispatch |
| frame loader entered; model load absent | descriptor/filter/model service creation |
| model load entered; `DoLoad` absent | medium or filter validation |
| `DoLoad` entered; `ImportFrom` absent | object-shell setup or a non-generic import branch |
| `ImportFrom` entered; `WriterFilter::filter` absent | filter service creation or UNO filter dispatch |
| writer filter entered; `resolve` absent | package, DomainMapper, or OOXML setup before resolution |
| `resolve` entered without exit | OOXML parsing/mapping scope; not root-cause proof by itself |
| `resolve` exited; stream clear absent | post-import grab-bag, theme, custom XML, or VBA handling |
| stream clear entered without exit | stream/DomainMapper teardown, including `RemoveLastParagraph` |
| import returned; view creation entered without `createViewController` | call-site/UNO transition before model controller creation |
| `createViewController` entered; model guard did not exit | SolarMutex acquisition plus model state/disposal checking; not SolarMutex root-cause proof |
| model guard exited; frame lookup entered without exit | existing-frame scan or conditional frame/view-frame creation |
| frame creation entered without exit | container-window lookup, `SfxFrame` construction, or frame-interface setup |
| frame preparation entered without exit | model args, descriptor update, or hidden/plugin-mode preparation |
| view-frame construction entered without exit | `SfxViewFrame` member construction, bindings, frame-view window, or work-window creation |
| frame lookup exited; factory did not enter | registration setup or the short pre-dispatch interval; frame creation scopes may be absent on reuse |
| factory entered; `SwWrtShell` did not enter | Writer factory dispatch or `SwView` base/member and pre-shell setup |
| `SwWrtShell` entered without exit | `SwWrtShell` construction; not a unique layout, lock, scheduler, or callee proof |
| `SwWrtShell` exited; factory did not exit | post-shell `SwView` setup, layout/field/TOX work, listeners, or render-state notification |
| factory exited; `createViewController` did not exit | controller association/creation, arguments, plugin-mode setup, or guard release |
| controller creation exited; frame/controller/model connection did not enter | call-site/UNO-reference transition between the two direct operations |
| model/controller connection entered without exit | one grouped `attachModel`, `connectController`, or `setCurrentController` call |
| model connection exited; component setup entered without exit | component-window retrieval or `XFrame::setComponent` |
| component setup exited; `attachFrame` entered before Sfx connection | SolarMutex, frame listener handling, or pre-connect work; not SolarMutex root-cause proof |
| Sfx connection entered; `EnableViewFrame` did not enter | view-shell/frame validation or the transition to `Enable`; no unique callee yet |
| a `ConnectSfxFrame::*` scope entered without exit | that direct synchronous operation or work below it; this does not identify a lock or wait primitive |
| `GetPluginMode` exited; visible or hidden setup entered without exit | the selected activation branch; the two branch markers are mutually exclusive |
| `UpdateTitle` exited; `ResizeViewFrame` entered without exit | forced non-in-place resize or work below it; not proof of a layout root cause |
| `GetViewData` entered without exit | model view-data acquisition; no view-data payload is logged |
| `GetViewData` exited; `ReadUserDataSequence` entered without exit | Writer view-data restore or work below it; not a unique cursor, zoom, layout, or shell-action proof |
| `InvalidateViewBinding` exited; Sfx connection did not exit | re-check the function epilogue before expanding beyond `ConnectSfxFrame_Impl` |
| Sfx connection exited; `attachFrame` did not exit | info bars or `ViewCreated` event construction/notification |
| `attachFrame` exited; frame/controller/model connection did not exit | optional modified-state re-enable or helper return handling |
| all thirteen create-view scopes exit; outer view creation does not | controller reference/caller/UNO/WASM propagation after view creation |
| all nested scopes return; outer LOK call does not | `LoadEnv` result/destruction, UNO return, or generated glue; do not blame Writer import |

If every native boundary returns, move investigation to the generated WASM glue
or Worker scheduling. No document fixtures, proprietary fonts, or production
WASM binaries belong in this repository.
