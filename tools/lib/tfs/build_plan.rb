# frozen_string_literal: true

module Tfs
  # The release-src build/copy plan: which versions must REPACK for the tag
  # being published, and which are CARRIED FORWARD from the previous release
  # as sha256-verified copies (tools/copy_asset). Fault isolation: a
  # patches/<line>/ change re-spends only that line's versions; a shared
  # tooling change correctly re-spends everything; a versions.yml change
  # re-spends exactly the versions whose entry moved (a new version has no
  # previous asset to copy, so it always builds). The PROGRESS/23 lesson:
  # no gratuitous rebuilds — an unchanged version's asset is copied, never
  # re-rolled.
  #
  # The release's asset set stays complete either way — consumers fetch the
  # full version set from any tag.
  class BuildPlan
    # versions:             Tfs::Versions of the tag being published.
    # diff:                 Tfs::ReleaseDiff for the tag being published.
    # previous_versions:    Tfs::Versions parsed at the previous release
    #                       tag; nil only when the diff has no previous tag.
    def initialize(versions:, diff:, previous_versions: nil)
      if diff.previous_tag && previous_versions.nil?
        raise ArgumentError, "previous_versions is required when the diff has a previous release tag"
      end

      @versions = versions
      @diff = diff
      @previous_versions = previous_versions
    end

    # Build rows: {version, tree, asset} — the release legs stage the tree
    # (tools/prepare) and roll the asset.
    def builds
      @versions.select { |entry| build_version?(entry) }
               .map { |entry| { version: entry.name, tree: entry.src_tree_name, asset: entry.asset_name } }
    end

    # Copy rows: one per unchanged version's asset.
    def copies
      @versions.reject { |entry| build_version?(entry) }
               .map { |entry| { version: entry.name, asset: entry.asset_name } }
    end

    private

    def build_version?(entry)
      return true if @diff.previous_tag.nil?
      return true if @diff.shared_change?

      previous = previous_entry(entry.name)
      return true if previous.nil? || state(previous) != state(entry)

      patch_lines = @diff.patch_lines
      !patch_lines.nil? && patch_lines.include?(entry.line)
    end

    def previous_entry(name)
      @previous_versions&.fetch(name)
    rescue KeyError
      nil
    end

    def state(entry)
      [entry.url, entry.sha256, entry.line]
    end
  end
end
