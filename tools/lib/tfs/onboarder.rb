# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Tfs
  # Onboards one new official CPython release end-to-end:
  #   1. fetch the official tarball (the URL the FTP index entry derives)
  #      and pin versions.yml — url + sha256 of the fetched bytes + line,
  #      with the scenario coverage inherited from the line's newest
  #      existing entry (a ported line never silently narrows back to
  #      linux-gnu-only because the monitor wrote the default);
  #   2. verify: re-read the pinned manifest and run SourcePrep#check
  #      (fetch via the new entry, sha256 verify, extract, tree sanity) —
  #      for a PATCHED line this includes applying the series in manifest
  #      order against the new pristine tree (the early warning that a
  #      series needs a versioned entry).
  # There is no manifest seeding for a NEW line (the ruby factory's step):
  # the windows-msys port lands per line deliberately (patches/README.md),
  # never by an optimistic copy onto an unproven line. On any failure
  # versions.yml is restored — nothing is released silently.
  class Onboarder
    # The outcome of one onboarding attempt; `error` carries the named
    # failure so the monitor workflow can file an issue with the detail.
    class Result
      def initialize(version:, verified:, written:, error: nil)
        @version = version
        @verified = verified
        @written = written
        @error = error
      end

      attr_reader :version, :written, :error

      def verified?
        @verified
      end

      def to_h
        { "version" => @version, "verified" => verified?, "error" => @error, "written" => @written }
      end
    end

    DEFAULT_REPO_ROOT = File.expand_path("../../..", __dir__).freeze

    def initialize(releases:, repo_root: DEFAULT_REPO_ROOT, cache_dir: SourcePrep::DEFAULT_CACHE_DIR)
      @releases = releases
      @repo_root = repo_root
      @versions_path = File.join(repo_root, "versions.yml")
      @cache_dir = cache_dir
    end

    def onboard(version_name)
      line = version_name.split(".")[0..1].join(".")
      written = []
      release = @releases.entry(version_name)

      original = File.read(@versions_path)
      _tarball, sha256 = prep.fetch_tarball(release.url, "Python-#{version_name}.tar.xz")
      add_version_entry(version_name, release.url, sha256, line, written)
      Dir.mktmpdir { |dir| prep.check(version_name, dir) }

      Result.new(version: version_name, verified: true, written: written.uniq)
    rescue SourcePrep::Error, KeyError => e
      File.write(@versions_path, original) if original
      Result.new(version: version_name, verified: false, written: [], error: e.message)
    end

    private

    # Built per call: after a pin, the next call's Versions re-reads the
    # updated versions.yml. The patch selection model rides along so
    # onboarding a new patch release of a PATCHED line (e.g. 3.14) also
    # apply-checks the line's series against the new pristine tree — the
    # early warning that a series needs a versioned entry.
    def prep
      SourcePrep.new(versions: Versions.new(@versions_path),
                     selection: PatchSelection.new(File.join(@repo_root, "patches")),
                     cache_dir: @cache_dir)
    end

    def add_version_entry(version_name, url, sha256, line, written)
      text = File.read(@versions_path)
      return if text.match?(/^  #{Regexp.escape(version_name)}:$/)

      lines = text.lines
      entry = ["  #{version_name}:\n",
               "    url: #{url}\n",
               "    sha256: #{sha256}\n",
               "    line: '#{line}'\n"]
      # Inherit the line's scenario coverage from its newest existing
      # entry (the default stays implicit — the key is written only when
      # it says something). A 3.14.x onboard must keep windows-msys, or the
      # new release would quietly ship no ucrt64 tree while its sibling
      # keeps one.
      scenarios = line_scenarios(line)
      entry << "    scenarios: [#{scenarios.join(', ')}]\n" if scenarios != Versions::DEFAULT_SCENARIOS
      idx = lines.index do |l|
        match = l.match(/^  (\d+\.\d+\.\d+):$/)
        match && Gem::Version.new(match[1]) > Gem::Version.new(version_name)
      end
      idx ? lines.insert(idx, *entry) : entry.each { |l| lines << l }
      File.write(@versions_path, lines.join)
      written << @versions_path
    end

    # The newest existing entry's scenarios for the line, defaulting to
    # DEFAULT_SCENARIOS when the line is new (or its entries predate the
    # scenario axis).
    def line_scenarios(line)
      siblings = Versions.new(@versions_path).select { |entry| entry.line == line }
      newest = siblings.max_by { |entry| Gem::Version.new(entry.name) }
      newest&.scenarios || Versions::DEFAULT_SCENARIOS
    end
  end
end
