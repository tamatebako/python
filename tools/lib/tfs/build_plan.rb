# frozen_string_literal: true

module Tfs
  # The release-src build/copy plan: which (version x scenario build) legs
  # must REPACK for the tag being published, and which are CARRIED FORWARD
  # from the previous release as sha256-verified copies (tools/copy_asset).
  # Fault isolation: a patches/<line>/ change re-spends only that line's
  # versions AND ONLY THE SCENARIOS THE CHANGED PATCHES FEED (an _msys
  # patch never re-rolls the POSIX tarball — the attribution is
  # ReleaseDiff#changed_scenarios); a shared tooling change correctly
  # re-spends everything, and a versions.yml change re-spends exactly the
  # versions whose entry moved (a new version has no previous asset to
  # copy, so it always builds). The PROGRESS/23 lesson: no gratuitous
  # rebuilds — an unchanged version's asset is copied, never re-rolled.
  #
  # The release's asset set stays complete either way — consumers fetch the
  # full matrix from any tag.
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

    # Build rows in Versions#builds shape plus the asset/tree names the
    # release-src legs package (the naming rule lives here, not in YAML).
    def builds
      rows_for(:build).map do |row|
        entry = @versions.fetch(row[:version])
        row.merge(tree: entry.src_tree_name, asset: asset_name(row))
      end
    end

    # Copy rows: one per unchanged (version x scenario build) asset.
    def copies
      rows_for(:copy).map { |row| row.slice(:version, :suffix).merge(asset: asset_name(row)) }
    end

    private

    def rows_for(action)
      @versions.builds.select { |row| (action == :build) == build_row?(row) }
    end

    def asset_name(row)
      "#{@versions.fetch(row[:version]).src_tree_name}#{row[:suffix]}.tar.gz"
    end

    # The row-level decision: the version-level reasons (first release,
    # shared tooling, the versions.yml entry moving) build every row of
    # the version; otherwise the row builds iff the line's changed
    # patches feed the row's scenario.
    def build_row?(row)
      return true if @diff.previous_tag.nil?
      return true if @diff.shared_change?

      entry = @versions.fetch(row[:version])
      previous = previous_entry(entry.name)
      return true if previous.nil? || state(previous) != state(entry)

      attributed_scenarios(entry.line).include?(row[:platform])
    end

    # The line's changed-scenario list, failing CLOSED: a line the diff
    # saw patch changes for but attributes nothing to (a shape the
    # suffix rules do not produce today) feeds every scenario — never
    # ship a possibly-stale copy.
    def attributed_scenarios(line)
      scenarios = @diff.changed_scenarios
      return Tfs::Versions::SCENARIOS if scenarios.nil?

      rows = scenarios.fetch(line, nil)
      return rows unless rows.nil?

      @diff.patch_lines&.include?(line) ? Tfs::Versions::SCENARIOS : []
    end

    def previous_entry(name)
      @previous_versions&.fetch(name)
    rescue KeyError
      nil
    end

    def state(entry)
      [entry.url, entry.sha256, entry.line, entry.scenarios]
    end
  end
end
