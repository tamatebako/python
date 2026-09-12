# frozen_string_literal: true

# TFS — tooling around the canonical tfs-python source set.
#
# Namespace parent: declares every in-library child via autoload.
# In-library files never require each other.
module Tfs
  autoload :Versions, "tfs/versions"
  autoload :SchemaLint, "tfs/schema_lint"
  autoload :SourcePrep, "tfs/source_prep"
  autoload :PatchManifest, "tfs/patch_manifest"
  autoload :PatchSelection, "tfs/patch_selection"
  autoload :HttpGet, "tfs/http_get"
  autoload :PythonReleases, "tfs/python_releases"
  autoload :Onboarder, "tfs/onboarder"
  autoload :ReleaseDiff, "tfs/release_diff"
  autoload :BuildPlan, "tfs/build_plan"
  autoload :SmokePlan, "tfs/smoke_plan"
  autoload :ReleaseCopier, "tfs/release_copier"
end
