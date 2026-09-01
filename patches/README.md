# patches/ — the tfs-python patch inventory

**The inventory is ZERO by design.** CPython ≥ 3.11 resolves its prefix at
runtime from the executable path (frozen `getpath.py`) and honors
`PYTHONHOME`; the macos-arm64 relocation probe (`docs/relocation-probe.md`)
built both pinned lines from these very tarballs, relocated the installed
trees, and ran stdlib-only scripts with no compiled-in path leakage. No
patch is needed to build a relocatable CPython from the pristine source.

Do not add a patch speculatively. A patch lands here only when a real,
reproduced failure demands one (a getpath quirk, a platform-specific
build break), and then:

1. one folder per line — `patches/<major.minor>/` — with a
   `patch-<line>.yaml` manifest validated against
   `schema/patches.schema.yml` (the harness already lints it);
2. the manifest/selection/apply machinery is ported from tamatebako/ruby
   (`Tfs::PatchManifest`, `Tfs::PatchSelection`, the `git apply` step in
   `Tfs::SourcePrep`) — the same model, not a new invention;
3. naming and the home-line rule follow tamatebako/ruby's README
   (`<feature>[_<patch_version>].patch`, snake_case, platform markers);
4. CI verifies every patch with `git apply --check` against the pristine
   tree of every version whose line it claims, before release.

Until then this directory carries only this README.
