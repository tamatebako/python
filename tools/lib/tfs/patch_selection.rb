# frozen_string_literal: true

module Tfs
  # Resolves the patch set for a CPython version from the per-line layout:
  # patches/<line>/patch-<line>.yaml (base) overlaid by
  # patches/<line>/patch-<line>.<patch>.yaml when present (more specific
  # wins per feature). Whole-line entries apply to every patch level;
  # an entry with version: "<patch>" applies only to that exact patch
  # level and supersedes the feature's whole-line entry for it. A feature
  # whose versioned entries do not cover the requested patch level is an
  # explicit error, never silent.
  #
  # With no scenario argument the full manifest set is returned (for
  # checking each patch independently). With +platform:+ the set is
  # narrowed to one coherent build scenario (the slug suffix convention:
  # a terminal _msys marks a windows-msys-only patch).
  #
  # Ported from tamatebako/ruby, slimmed: python has no GNUmakefile
  # two-pass flow, so there is no pass axis.
  class PatchSelection
    # One resolved patch: manifest entry + absolute file path.
    class Patch
      def initialize(path:, feature:, version:)
        @path = path
        @feature = feature
        @version = version
      end

      attr_reader :path, :feature, :version

      def name
        File.basename(@path)
      end

      def line_wide?
        @version.nil?
      end

      def patchlevel
        @version
      end

      # First target file inside the CPython source tree (from the patch
      # header). A multi-file patch (e.g. configure.ac + the generated
      # configure) still applies as one unit; the first header drives the
      # platform-override dedup and the target-exists check.
      def target_file
        @target_file ||= begin
          header = File.foreach(@path).find { |line| line.start_with?("+++ b/") }
          raise ArgumentError, "#{@path}: no '+++ b/' header found" if header.nil?

          header.strip.sub(%r{\A\+\+\+ b/}, "")
        end
      end
    end

    # Raised when a version's set cannot be resolved from the manifests.
    # Carries the offending feature (nil for structural failures such as a
    # missing line manifest) so callers can react per feature.
    class SelectionError < StandardError
      def initialize(message, feature: nil, version_name: nil)
        super(message)
        @feature = feature
        @version_name = version_name
      end

      attr_reader :feature, :version_name
    end

    DEFAULT_ROOT = File.expand_path("../../../patches", __dir__).freeze

    PLATFORM_SUFFIXES = %w[_msys].freeze
    PLATFORM_TAGS = {
      "linux-gnu" => nil,
      "windows-msys" => "msys", "msys" => "msys", "mingw" => "msys"
    }.freeze

    def initialize(patches_root = DEFAULT_ROOT)
      @patches_root = patches_root
    end

    def for(version_name, platform: nil)
      candidates = resolve(version_name)
      candidates = filter_platform(candidates, platform) unless platform.nil?
      candidates
    end

    # Does the version's line carry a patch manifest? (An unpatched line
    # is legitimate here — unlike the ruby factory, where every line is
    # patched by construction.)
    def line_manifest?(version_name)
      line = version_name.split(".")[0..1].join(".")
      File.file?(File.join(@patches_root, line, "patch-#{line}.yaml"))
    end

    private

    def resolve(version_name)
      line, patchlevel = version_name.split(".").then { |parts| [parts[0..1].join("."), parts[2]] }
      line_dir = File.join(@patches_root, line)
      base_path = File.join(line_dir, "patch-#{line}.yaml")
      unless File.file?(base_path)
        raise SelectionError, "#{version_name}: no patch manifest #{base_path}"
      end

      merged = merge_base(PatchManifest.new(base_path).entries)
      overlay_path = File.join(line_dir, "patch-#{version_name}.yaml")
      merge_overlay!(merged, PatchManifest.new(overlay_path).entries) if File.file?(overlay_path)

      merged.flat_map { |feature, entries| select_entries(feature, entries, patchlevel, version_name, line_dir) }
    end

    def merge_base(entries)
      merged = {}
      entries.each { |entry| (merged[entry.feature] ||= []) << entry }
      merged
    end

    def merge_overlay!(merged, entries)
      entries.each { |entry| merged[entry.feature] = [entry] }
      merged
    end

    def select_entries(feature, entries, patchlevel, version_name, line_dir)
      exact = entries.select { |entry| entry.exact_for?(patchlevel) }
      chosen = exact.any? ? exact : entries.select(&:whole_line?)
      if chosen.empty?
        raise SelectionError.new(
          "#{version_name}: feature #{feature} has no entry covering patch level #{patchlevel}",
          feature: feature, version_name: version_name
        )
      end

      chosen.map do |entry|
        Patch.new(path: File.expand_path(entry.file, line_dir), feature: feature, version: entry.version)
      end
    end

    def filter_platform(candidates, platform)
      tag = PLATFORM_TAGS.fetch(platform) { raise ArgumentError, "unknown platform #{platform.inspect}" }
      kept = candidates.reject do |patch|
        suffix = platform_suffix(patch)
        !suffix.nil? && suffix != tag
      end
      return kept unless tag == "msys"

      msys_targets = kept.select { |patch| platform_suffix(patch) == "msys" }.map(&:target_file).uniq
      kept.reject { |patch| platform_suffix(patch).nil? && msys_targets.include?(patch.target_file) }
    end

    def platform_suffix(patch)
      PLATFORM_SUFFIXES.find { |suffix| patch.feature.end_with?(suffix) }&.delete_prefix("_")
    end
  end
end
