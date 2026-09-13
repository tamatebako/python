# patches/ — the tfs-python patch inventory

One folder per patched line — `patches/<major.minor>/` — with a
`patch-<line>.yaml` manifest validated against `schema/patches.schema.yml`
(the harness lints it in CI before any use). The manifest/selection/apply
machinery is the tamatebako/ruby model ported (`Tfs::PatchManifest`,
`Tfs::PatchSelection`, the `git apply` step in `Tfs::SourcePrep`) — the
same model, not a new invention; naming and the home-line rule follow
tamatebako/ruby's README (`<feature>[_<patch_version>].patch`, snake_case,
platform markers).

Today the inventory carries exactly one series: **`patches/3.14/`, the
msys2/ucrt64 port** (motivating wall, tebako-runtime-python PR #2:
upstream `configure.ac` has zero mingw cases, `pyconfig.h.in` lacks
`MS_WINDOWS`, `pylifecycle.c`'s `setenv` and `pytime.c`'s `timeval` branch
hard-stop the ucrt64 build). Every entry of a windows-only series is
`_msys`-suffixed: the suffix is what `Tfs::PatchSelection` filters on, so
the unsuffixed `linux-gnu` asset stays byte-identical with the pristine
upstream tarball.

## Why the *base* set is empty

CPython ≥ 3.11 resolves its prefix at runtime from the executable path
(frozen `getpath.py`) and honors `PYTHONHOME`; the macos-arm64 relocation
probe (`docs/relocation-probe.md`) built both pinned lines from these very
tarballs, relocated the installed trees, and ran stdlib-only scripts with
no compiled-in path leakage. No patch is needed to build a relocatable
CPython from the pristine source — so a patch lands here only when a real,
reproduced failure demands one (a getpath quirk, a platform-specific build
break like the ucrt64 wall), never speculatively.

## The rules (mirrored from tamatebako/ruby)

1. Patches are machine-verified unified diffs; the header comment cites
   the source (upstream issue, MSYS2 MINGW-packages patch) and restates
   the rationale. The 3.14 series ports the proven MSYS2 out-of-tree port,
   not new invention.
2. `git apply --check` of every selected patch against the pristine tree
   of every version whose line it claims runs in `tools/lint` (CI,
   per-version legs); `tools/compile_smoke` compiles the wall TUs of the
   patched tree on the scenario's native runner (PR-time via lint.yml,
   release-time as release-src.yml's publish gate).
3. Platform-conditional features carry the terminal platform marker
   (`_msys`); a feature without one applies to every scenario (and re-rolls
   every scenario's asset — choose deliberately).
4. A patch tied to one exact patch release gets an overlay
   `patch-<line>.<patch>.yaml` entry (`version: "<patch>"`); a feature
   whose versioned entries don't cover a version is a named
   `SelectionError`, never silent.
5. The generated `configure` is patched IN LOCKSTEP with `configure.ac`
   (hand-synced hunks): this factory ships configure-ready tarballs —
   consumers never run autoconf.
