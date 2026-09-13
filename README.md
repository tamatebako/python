# tamatebako/python — the CPython source factory (tfs-python)

The **python source factory** of the tebako ecosystem (v2): the canonical
`versions.yml` of supported upstream CPython releases plus the machinery
that turns each into a verified, reproducible **`tfs-python-<version>-src.tar.gz`**
release asset for the runtime factory (tebako-runtime-python) to consume.
Modeled on tamatebako/ruby (the ruby source factory) — same layout, same
contracts, same lessons.

**Status: live.** Releases (`v*`) carry the per-version
`tfs-python-<version>-src[-<scenario>].tar.gz` assets + `SHA256SUMS`;
tebako-runtime-python consumes them by pin (`contract.yml`'s
`source_release`).

## What a tarball is (the factory contract)

Each release asset `tfs-python-<version>-src[-<scenario>].tar.gz` contains
exactly one top-level tree `tfs-python-<version>-src/`: the **pristine
upstream CPython source** of `<version>` — fetched from the official
`https://www.python.org/ftp/python/<v>/Python-<v>.tar.xz`, sha256-verified
against the pin in `versions.yml`, extracted, staged under the release
name — plus the scenario's patch set applied (`patches/<line>/`). The
unsuffixed `linux-gnu` asset is the back-compat contract: every version's
linux-gnu tree carries the line's *base* patch set, which today is empty —
byte-for-byte the upstream tree (`docs/relocation-probe.md` is why no
relocation patch is needed). A version declaring a scenario in
`versions.yml` (`scenarios: [linux-gnu, windows-msys]`) additionally ships
the suffixed asset of that scenario's patched tree — the 3.14 line's
`windows-msys` series is the msys2/ucrt64 port.

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
  tarball URL, sha256, major.minor line, and the platform `scenarios` it
  ships src releases for (absent means linux-gnu only). **The lines are
  pinned to the dependency graph, not to upstream's newest** (the
  driving payload is xml2rfc — see the file's
  header comment for the current `requires_python` and the per-version
  sha256 cross-check provenance).
- `schema/` — JSON Schemas: `versions.schema.yml` for `versions.yml`,
  `patches.schema.yml` for the patch manifests. CI validates before use
  (`tools/validate_manifests`).
- `patches/` — one folder per patched line (`patches/3.14/` today: the
  windows-msys port) with a `patch-<line>.yaml` manifest. Layout, naming,
  the home-line rule, and the manifest/selection model follow
  tamatebako/ruby's README exactly (see `patches/README.md`).
- `tools/` — thin executables over the model classes in `tools/lib/tfs/`
  (namespace parent `tools/lib/tfs.rb` wires children with `autoload`).
- `spec/` — offline tooling specs (`bundle exec rspec`): manifest
  parsing, release detection/diffing, source prep against a tiny fixture
  tarball, the diff-aware build plan, verified carry-forward copies,
  onboarding — no network anywhere (dead `127.0.0.1:1` URLs and
  cache-seeded fixtures).
- `docs/relocation-probe.md` — the empirical evidence behind the empty
  *base* patch set: both pinned lines built from these tarballs on
  macos-arm64, relocated, and verified (prefix resolution + ssl + json,
  with and without `PYTHONHOME`, no compiled-in path leakage).

## Tooling (`tools/`)

- `tools/versions [--scenarios|--smoke]` — prints versions.yml as a GitHub
  Actions matrix document. Default: `{"version":[...]}`, one leg per
  version. `--scenarios`: the flat (version × scenario build) release
  matrix. `--smoke`: the patch-carrying rows only (the PR-time
  compile-smoke matrix).
- `tools/prepare <version> [outdir]` — emits
  `<outdir>/tfs-python-<version>-src`: fetch (sha256-verified, cached in
  `.cache/tarballs`, override with `TFS_CACHE_DIR`), extract, stage, and
  apply the linux-gnu scenario's patch set (empty today — the unsuffixed
  asset stays byte-identical with the pristine upstream tarball).
- `tools/apply <version> [outdir] [--platform NAME]` — the general form:
  stages the tree with one coherent scenario's patch set applied
  (`Tfs::PatchSelection`; `windows-msys` applies the line's `_msys`
  series).
- `tools/compile_smoke <version> [outdir] [--platform NAME]` — the compile
  gate: stages the scenario tree, configures in-tree, and compiles the
  wall translation units (the tebako-runtime-python PR #2 evidence:
  `Python/pylifecycle.o`, `Python/pytime.o`, `Programs/python.o`; the
  PR #16 errmap wall: `Objects/exceptions.o` — the set is a regression
  list, every factory windows wall TU joins it in the fixing PR) plus any
  `.c` target the scenario's patches name. windows-msys runs natively
  under msys2 ucrt64 (never a cross compile).
- `tools/smoke_matrix <release-tag>` — the release compile-smoke matrix:
  one leg per (changed patch line × affected scenario) at the line's
  newest version (`Tfs::SmokePlan` over the same `Tfs::ReleaseDiff` the
  build/copy plan uses — an `_msys` patch never smokes linux-gnu).
- `tools/lint <version>` — fetch + verify + extract + tree sanity
  (`configure`, `Makefile.pre.in`, `Modules/getpath.py` — the file the
  relocatability contract rests on), plus applying every patch the
  version's line manifest selects, in manifest order, on a pristine tree
  (the series is cumulative — a patch's context may assume its
  predecessors).
- `tools/monitor --detect | --onboard <version>` — the release monitor.
  `Tfs::PythonReleases` parses the official python.org FTP index
  (exact `X.Y.Z` directories only — pre-release suffixes and the two-part
  aliases never match) and diffs against versions.yml (newer patch
  releases of tracked lines; the latest release of an untracked line
  inside the support window). A directory is not proof of release —
  upstream creates `<v>/` with the line's first alpha — so a candidate
  counts only when its final tarball `Python-<v>.tar.xz` answers a HEAD
  probe; a 404 means simply not new (no onboard attempt, no issue).
  `Tfs::Onboarder` onboards one release end-to-end: pins it into
  versions.yml (derived official URL + sha256 of the fetched tarball) and
  re-verifies the new entry end-to-end (fetch, sha256, extract, tree
  sanity — and, for a patched line, the series' apply check against the
  new pristine tree: the early warning that a series needs a versioned
  entry). On any failure versions.yml is restored — nothing is released
  silently.
- `tools/validate_manifests` — validates versions.yml and every
  `patch-*.yaml` against `schema/`; run in CI before the manifests are
  used.
- `tools/build_matrix <release-tag> [--build|--copies|--previous-tag]` —
  release-src's diff-aware plan (`Tfs::ReleaseDiff` + `Tfs::BuildPlan`):
  which (version × scenario) rows must repack for this tag (changed patch
  line — only the scenarios the changed patches feed; moved versions.yml
  entry; shared tooling change — fail closed; or first release) and which
  are carried forward. **Repack-on-bump only** — an unchanged row is a
  verified copy, never a gratuitous rebuild.
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
  version running `tools/lint` (tarball + tree sanity + the selected
  patch series applied in manifest order), plus the **compile-smoke legs**
  (`tools/versions --smoke` → `_compile-smoke.yml`, one leg per
  patch-carrying scenario on its native runner — the PR-time oracle for
  the windows-msys port, since a local macOS/Linux host cannot run the
  ucrt64 toolchain natively).
- `release-monitor.yml` (daily 05:43 UTC + manual dispatch) — detects new
  official CPython releases and onboards each on its own lane: a clean
  onboard opens an "Onboard python X.Y.Z" pull request
  (peter-evans/create-pull-request); a failing one files an issue with
  the error detail — or comments the recurrence date on the existing open
  issue of the same title (a persistent failure never files duplicates).
  **Merge gate for a NEW line:** check it against xml2rfc's
  `requires_python` before merge (the PR body says so — the
  monitor detects, a human gates). No downstream dispatch exists yet —
  tebako-runtime-python consumes releases through its `contract.yml`
  `source_release` pin; an automatic bump dispatch can be added there.
- `release-src.yml` (tags `v*` + manual dispatch) — the diff-aware
  repack: `plan` (tools/build_matrix + tools/smoke_matrix) → `smoke`
  (the changed lines' compile gate, `_compile-smoke.yml`) → `build` legs
  (scenario apply, clamped roll, extract-verify) + `copy` legs (verified
  carry-forward) → `publish` (SHA256SUMS + GitHub release). Flat
  matrices — the ruby factory's per-line fan-out (`_release-line.yml`)
  exists for 30+ versions across 5 lines; split per-line here when the
  count grows.

## The mount root

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
- Python therefore mints no mount-root literal of its own. The runtime's
  mount point is a driver/factory contract value (tebako-runtime-python
  sets `PYTHONHOME` to the env image's mount point at boot); when the
  python runtime mounts at the canonical `/__tfs__` spelling, the value
  FLOWS from the ruby factory's manifest — never a second hand-written
  copy. Nothing in this repo hard-codes either spelling.

## Local development

```
bundle install
bundle exec rspec              # the offline tooling specs
bundle exec tools/validate_manifests
tools/lint 3.13.15             # network: fetches + verifies the pin
tools/prepare 3.13.15 build    # stages build/tfs-python-3.13.15-src
tools/apply 3.14.7 build --platform windows-msys
                               # stages the patched windows-msys tree
tools/compile_smoke 3.14.7     # the compile gate; windows-msys needs a
                               # windows runner (msys2 ucrt64) — on this
                               # host only the linux-gnu leg runs
```

Note on `bundle install` outside CI: the committed `.bundle/config` pins
CI's runner path; point bundler elsewhere locally, e.g.
`BUNDLE_APP_CONFIG=/tmp/tfs-python-bundle BUNDLE_PATH=.vendor/bundle bundle install`.
