# LibreOffice WASM diagnostic builder

An isolated, reproducible GitHub Actions project for compiling one diagnostic
LibreOffice WASM runtime. It exists only to locate the native boundary of the
browser `documentLoad` / `documentSaveAs` hang; it is not a production
LibreOffice fork or a runtime distribution repository.

## Pinned inputs

- LibreOffice branch: `libreoffice-24-8`
- LibreOffice commit: `d1c9e0e4e1ddeb24fe8f93e56860b3765043f8b1`
- Emscripten SDK: `3.1.74`
- WASM compatibility patch: `patches/wasm-build-fixes.patch`
- Native save/export trace patch: `patches/libreoffice-24-8-saveas-native-markers.patch`
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

The build emits ES6 glue as `soffice.mjs` (and optionally `soffice.worker.mjs`).
The collect step renames those into the published artifact names below.

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

The build verifies that the final `soffice.wasm` contains both
`LOK_SAVEAS_TRACE` and `LOK_LOAD_TRACE` marker strings before publishing it.

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
[LOK_SAVEAS_TRACE]
[LOK_LOAD_TRACE]
```

The first boundary with an `entry` and no matching `exit` identifies the native
hang scope. The load markers cover `SolarMutexGuard`, `frame::Desktop::create`,
`loadComponentFromURL`, and `LibLODocument_Impl` before save/export begins. If
every native boundary returns, move investigation to generated WASM glue or
Worker scheduling.

No document fixtures, proprietary fonts, or production WASM binaries belong in
this repository.
