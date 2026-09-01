# tamatebako/python — the CPython source factory (tfs-python)

The **python source factory** of the tebako ecosystem (v2): the canonical
`versions.yml` of supported upstream CPython releases plus the machinery
that turns each into a verified, reproducible **`tfs-python-<version>-src.tar.gz`**
release asset for the runtime factory (tebako-runtime-python,
TODO.python/02) to consume. Modeled on tamatebako/ruby (the ruby source
factory) — same layout, same contracts, same lessons.

**Status: DRAFT.** This scaffold was built and validated locally
(macos-arm64) ahead of the GitHub repo creation; nothing here has been
pushed or published. The workflows are written for the future
`tamatebako/python` repo and become live only when it exists.

## What a tarball is (the factory contract)

Each release asset `tfs-python-<version>-src.tar.gz` contains exactly one
top-level tree `tfs-python-<version>-src/`: the **pristine upstream
CPython source** of `<version>` — fetched from the official
`https://www.python.org/ftp/python/<v>/Python-<v>.tar.xz`, sha256-verified
against the pin in `versions.yml`, extracted, and staged under the release
name. The **patch inventory is ZERO** (`patches/README.md`): today the
staged tree is byte-for-byte the upstream tree; when the first patch
lands, it applies between extraction and staging and this paragraph
shrinks to "pristine + the line's patch set".

Every tarball is packed with **all tar metadata clamped**
(`tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner`; the
gzip header is already MTIME=0 through the pipe), so its sha256 is
content-addressed: identical trees package to identical bytes. Downstream
consumers key their build caches on that sha256 — a plain `tar -czf`
stamps checkout-time mtimes and readdir order, cold-caching every
downstream build for changes that touched nothing. Never reintroduce one
(the tamatebako/ruby README states the same law for tfs-ruby).

Each release also publishes `SHA256SUMS` over the full asset set; the
per-version sum is the trust anchor the runtime factory verifies against.

## Layout

- `versions.yml` — every supported CPython version with its official
  tarball URL, sha256, and major.minor line. **The lines are pinned to
  the dependency graph, not to upstream's newest** (the PROGRESS/25
  lesson; the driving payload is xml2rfc — see the file's header comment
  for the current `requires_python` and the per-version sha256
  cross-check provenance).
- `schema/` — JSON Schemas: `versions.schema.yml` for `versions.yml`,
  `patches.schema.yml` for the patch manifests that arrive with the first
  patch. CI validates before use (`tools/validate_manifests`).
- `patches/` — **empty by design** (`patches/README.md`: why zero, and
  the exact mechanics for adding the first patch — the
  manifest/selection/apply model is ported from tamatebako/ruby when
  needed, not invented here).
- `tools/` — thin executables over the model classes in `tools/lib/tfs/`
  (namespace parent `tools/lib/tfs.rb` wires children with `autoload`).
- `spec/` — offline tooling specs (`bundle exec rspec`): manifest
  parsing, release detection/diffing, source prep against a tiny fixture
  tarball, the diff-aware build plan, verified carry-forward copies,
  onboarding — no network anywhere (dead `127.0.0.1:1` URLs and
  cache-seeded fixtures).
- `docs/relocation-probe.md` — the empirical evidence behind the zero
  patch inventory: both pinned lines built from these tarballs on
  macos-arm64, relocated, and verified (prefix resolution + ssl + json,
  with and without `PYTHONHOME`, no compiled-in path leakage).

## Tooling (`tools/`)

- `tools/versions` — prints versions.yml as a GitHub Actions matrix
  document (`{"version":[...]}`, one leg per version).
- `tools/prepare <version> [outdir]` — emits
  `<outdir>/tfs-python-<version>-src`: fetch (sha256-verified, cached in
  `.cache/tarballs`, override with `TFS_CACHE_DIR`), extract, stage.
- `tools/lint <version>` — the zero-patch verification gate: fetch +
  verify + extract + tree sanity (`configure`, `Makefile.pre.in`,
  `Modules/getpath.py` — the file the relocatability contract rests on).
  When patches exist, their `git apply --check` joins this lint.
- `tools/monitor --detect | --onboard <version>` — the release monitor.
  `Tfs::PythonReleases` parses the official python.org FTP index
  (exact `X.Y.Z` directories only — pre-releases never match) and diffs
  against versions.yml (newer patch releases of tracked lines; the latest
  release of an untracked line inside the support window).
  `Tfs::Onboarder` onboards one release end-to-end: pins it into
  versions.yml (derived official URL + sha256 of the fetched tarball) and
  re-verifies the new entry end-to-end (fetch, sha256, extract, tree
  sanity). On any failure versions.yml is restored — nothing is released
  silently.
- `tools/validate_manifests` — validates versions.yml and every
  `patch-*.yaml` against `schema/`; run in CI before the manifests are
  used.
- `tools/build_matrix <release-tag> [--build|--copies|--previous-tag]` —
  release-src's diff-aware plan (`Tfs::ReleaseDiff` + `Tfs::BuildPlan`):
  which versions must repack for this tag (changed patch line, moved
  versions.yml entry, shared tooling change — fail closed, or first
  release) and which are carried forward. **Repack-on-bump only** — the
  PROGRESS/23 lesson: an unchanged version is a verified copy, never a
  gratuitous rebuild.
- `tools/copy_asset <previous-tag> <asset> <dest-dir>` — the
  carry-forward half: downloads one asset from the previous release,
  sha256-verifies the bytes against that release's published SHA256SUMS
  (`Tfs::ReleaseCopier`), and writes `<asset>.sha256` next to it. A failed
  verification is a named error and deletes the download — a bad copy
  never ships.

## CI (`.github/workflows/`)

All matrices and every version/sha flow from versions.yml through the
tools — the workflows carry no version literals.

- `lint.yml` (push to main + PRs) — validates manifests, then one leg per
  version running `tools/lint`.
- `release-monitor.yml` (daily 05:43 UTC + manual dispatch) — detects new
  official CPython releases and onboards each on its own lane: a clean
  onboard opens an "Onboard python X.Y.Z" pull request
  (peter-evans/create-pull-request); a failing one files an issue with
  the error detail. **Merge gate for a NEW line:** check it against
  xml2rfc's `requires_python` before merge (the PR body says so — the
  monitor detects, a human gates). No downstream dispatch exists yet —
  tebako-runtime-python is TODO.python/02; add it there when that repo
  lands.
- `release-src.yml` (tags `v*` + manual dispatch) — the diff-aware
  repack: `plan` (tools/build_matrix) → `build` legs (prepare, clamped
  roll, extract-verify) + `copy` legs (verified carry-forward) →
  `publish` (SHA256SUMS + GitHub release). Flat matrices — the ruby
  factory's per-line fan-out (`_release-line.yml`) exists for 30+
  versions across 5 lines; split per-line here when the count grows. No
  compile-smoke gate: the ruby factory's smoke compiles *patched*
  translation units, and this factory has no patches — the gate returns
  with the first one.

## SSOT: the mount root (PROPOSED — pending owner)

tamatebako/ruby owns the `/__tfs__`-style mount-root literal for ruby:
the patch content is the single owner, and the value FLOWS from the
applied tree's `tebako-mount-root` manifest down the chain. Python's
situation is different by construction (probe evidence:
`docs/relocation-probe.md`):

- CPython ≥ 3.11 needs **no baked root literal**: the frozen
  `Modules/getpath.py`
  resolves the prefix at runtime from the executable path, and
  `PYTHONHOME` overrides it. The env image mounts wherever the driver
  decides, and the interpreter follows — there is no compiled-in path
  to own or patch.
- **PROPOSED:** python does not mint a second mount-root literal at all.
  The runtime's mount point is a driver/factory contract value
  (tebako-runtime-python sets `PYTHONHOME` to the env image's mount point
  at boot — the PROGRESS/27 §3 "driver sets env at boot" shape), and the
  canonical VFS spelling for runtime roots remains owned by
  tamatebako/ruby (`/__tfs__`) — if the python runtime mounts at that
  same path, the value FLOWS from the ruby factory's manifest, never a
  second hand-written copy. Alternative if the owner prefers per-runtime
  roots: tamatebako/python becomes the owner of a python-specific root
  literal and every consumer flows it from here. **Decision pending the
  owner; nothing in this repo hard-codes either spelling.**

## Local development

```
bundle install
bundle exec rspec              # the offline tooling specs
bundle exec tools/validate_manifests
tools/lint 3.13.15             # network: fetches + verifies the pin
tools/prepare 3.13.15 build    # stages build/tfs-python-3.13.15-src
```
