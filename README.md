# LibreOffice WASM diagnostic builder

An isolated, reproducible GitHub Actions project for compiling one diagnostic
LibreOffice WASM runtime. The current build is intentionally pinned to the
Matbee package-classic `importScripts(soffice.js)` shape and the `load-v2`
native marker set so it can locate the deepest active browser `documentLoad`
scope. It is not a production LibreOffice fork or a runtime distribution
repository.

## Pinned inputs

- LibreOffice branch: `libreoffice-24-8`
- LibreOffice commit: `d1c9e0e4e1ddeb24fe8f93e56860b3765043f8b1`
- Emscripten SDK: `3.1.74`
- Diagnostic glue mode: `package-classic`
- Diagnostic marker set: `load-v2`
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
`soffice.wasm` contains `LOK_LOAD_TRACE` and every required `load-v2` boundary,
and that it does not contain `LOK_SAVEAS_TRACE`. `BUILD-METADATA.txt` records
`package-classic`, `load-v2`, and the pinned patch hashes.

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

Every new nested boundary is an RAII scope, so exceptions and ordinary returns
produce a matching `exit`. The marker set brackets only top-level functions or
single O(1)-per-load calls; it deliberately excludes DomainMapper per-element
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
15. `LibLODocument_Impl`

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
| import returned; view creation entered without exit | view, layout, or controller construction |
| all nested scopes return; outer LOK call does not | `LoadEnv` result/destruction, UNO return, or generated glue; do not blame Writer import |

If every native boundary returns, move investigation to the generated WASM glue
or Worker scheduling. No document fixtures, proprietary fonts, or production
WASM binaries belong in this repository.
