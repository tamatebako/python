# frozen_string_literal: true

module Tfs
  # The compile-smoke leg plan (release-src's publish gate): one
  # representative leg per (changed line x affected scenario) at the
  # line's NEWEST version, computing from the same Tfs::ReleaseDiff the
  # build/copy plan uses.
  #
  # Two fault-isolation axes, both from the diff:
  #
  # * line: only lines whose patch set changed smoke at all;
  # * scenario: only the scenarios the changed patches FEED smoke
  #   (Tfs::ReleaseDiff#changed_scenarios — an _msys patch never smokes
  #   linux-gnu). A line whose attribution is explicitly empty smokes
  #   nothing.
  #
  # A line-wide patch set means a representative leg per (line, scenario)
  # covers the changed translation units; per-version legs would multiply
  # configure runs for no extra signal.
  #
  # Ported from tamatebako/ruby, slimmed: no pass axis.
  class SmokePlan
    # versions: Tfs::Versions of the tag being published.
    # diff:     Tfs::ReleaseDiff for the tag being published.
    def initialize(versions:, diff:)
      @versions = versions
      @diff = diff
    end

    # The leg rows: {line:, version:, platform:} per (changed line x
    # affected scenario), the newest version of each.
    def legs
      per_line = @versions.flat_map do |entry|
        next [] unless include_entry?(entry)

        affected_scenarios(entry).map { |scenario| { line: entry.line, version: entry.name, platform: scenario } }
      end
      per_line.group_by { |leg| [leg[:line], leg[:platform]] }
              .map { |(_line, _platform), group| group.max_by { |leg| Gem::Version.new(leg[:version]) } }
    end

    private

    def include_entry?(entry)
      return true if @diff.patch_lines.nil?

      @diff.patch_lines.include?(entry.line)
    end

    def affected_scenarios(entry)
      scenarios = @diff.changed_scenarios
      return entry.scenarios if scenarios.nil?

      entry.scenarios & scenarios.fetch(entry.line, [])
    end
  end
end
