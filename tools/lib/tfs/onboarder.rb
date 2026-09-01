# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Tfs
  # Onboards one new official CPython release end-to-end:
  #   1. fetch the official tarball (the URL the FTP index entry derives)
  #      and pin versions.yml — url + sha256 of the fetched bytes + line;
  #   2. verify: re-read the pinned manifest and run SourcePrep#check
  #      (fetch via the new entry, sha256 verify, extract, tree sanity).
  # With a zero patch inventory there is no manifest seeding or partition
  # extension (the ruby factory's steps 2–4); those land with the first
  # patch. On any failure versions.yml is restored — nothing is released
  # silently.
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
    # updated versions.yml.
    def prep
      SourcePrep.new(versions: Versions.new(@versions_path), cache_dir: @cache_dir)
    end

    def add_version_entry(version_name, url, sha256, line, written)
      text = File.read(@versions_path)
      return if text.match?(/^  #{Regexp.escape(version_name)}:$/)

      lines = text.lines
      entry = ["  #{version_name}:\n",
               "    url: #{url}\n",
               "    sha256: #{sha256}\n",
               "    line: '#{line}'\n"]
      idx = lines.index do |l|
        match = l.match(/^  (\d+\.\d+\.\d+):$/)
        match && Gem::Version.new(match[1]) > Gem::Version.new(version_name)
      end
      idx ? lines.insert(idx, *entry) : entry.each { |l| lines << l }
      File.write(@versions_path, lines.join)
      written << @versions_path
    end
  end
end
