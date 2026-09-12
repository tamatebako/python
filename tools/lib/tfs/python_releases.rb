# frozen_string_literal: true

module Tfs
  # The official CPython releases (the python.org FTP index of per-version
  # directories) and the diff against the versions.yml set. The index lists
  # directories only, so each release's tarball URL is DERIVED from its
  # version — the layout is fixed upstream (ftp/python/<v>/Python-<v>.tar.xz).
  #
  # Directory presence is NOT releasedness: upstream creates <v>/ with the
  # line's first PRE-RELEASE (ftp/python/3.15.0/ has served
  # Python-3.15.0a1… for months while Python-3.15.0.tar.xz still 404s).
  # A version therefore counts as released ONLY when its final tarball
  # answers the tarball probe — trusting the directory is what made the
  # monitor onboard-attempt an unreleased 3.15.0 every day (the
  # tamatebako/python #3–#13 duplicate issues).
  class PythonReleases
    INDEX_URL = "https://www.python.org/ftp/python/"

    # Apache index hrefs of exact release directories (href="3.13.15/").
    # Digits only: pre-release directories (3.15.0a1/, 3.14.0rc1/) and the
    # two-part aliases (3.13/) never match.
    DIR_FORMAT = %r{href="(\d+\.\d+\.\d+)/"}.freeze

    # One official release.
    class Release
      def initialize(name:)
        @name = name
        @line = name.split(".")[0..1].join(".")
      end

      attr_reader :name, :line

      def url
        "https://www.python.org/ftp/python/#{name}/Python-#{name}.tar.xz"
      end
    end

    # Fetches and parses the official FTP index.
    def self.fetch(url = INDEX_URL)
      new(Tfs::HttpGet.body(url))
    end

    # tarball_probe: #call(url) -> bool — whether a version's FINAL tarball
    # is published (Tfs::HttpGet.method(:exists?) in production; a stub in
    # specs).
    def initialize(html, tarball_probe: Tfs::HttpGet.method(:exists?))
      @releases = html.scan(DIR_FORMAT).flatten.uniq.map { |name| Release.new(name: name) }.freeze
      @tarball_probe = tarball_probe
    end

    attr_reader :releases

    def names
      @releases.map(&:name)
    end

    def entry(name)
      release = @releases.find { |candidate| candidate.name == name }
      raise KeyError, "python #{name} is not an official release" if release.nil?

      release
    end

    # Released versions that are not onboarded yet: a newer patch release
    # of a line versions.yml tracks, or the latest release of an untracked
    # line inside the support window (>= the oldest tracked line) — and in
    # every case only when the FINAL tarball is actually published (a
    # pre-release staging directory never counts as its final form; a/b/rc
    # suffixes never parse into releases at all). Older patch releases and
    # lines below the window are not candidates.
    # Sorted ascending (onboard oldest first).
    #
    # NOTE: a new LINE is a candidate so a human reviews it — the merge
    # gate is xml2rfc's requires_python (versions.yml's header comment),
    # not this model.
    def new_versions(versions)
      max_of_line = versions.each_with_object({}) do |entry, acc|
        name = entry.name
        if acc[entry.line].nil? || Gem::Version.new(name) > Gem::Version.new(acc[entry.line])
          acc[entry.line] = name
        end
      end
      min_line = max_of_line.keys.min_by { |line| Gem::Version.new(line) }
      latest_of_line = @releases.group_by(&:line).to_h do |line, releases|
        [line, releases.map(&:name).max_by { |name| Gem::Version.new(name) }]
      end
      @releases
        .select { |release| candidate?(release, max_of_line, min_line, latest_of_line) }
        .select { |release| published?(release) }
        .sort_by { |release| Gem::Version.new(release.name) }
    end

    private

    # A candidate whose final tarball does not answer 200 is not a release
    # yet — it is simply not reported (never an onboard attempt, never an
    # issue), with a stderr note so the daily run's log says why.
    def published?(release)
      return true if @tarball_probe.call(release.url)

      warn "python #{release.name}: skipped — the final tarball is not published yet (#{release.url})"
      false
    end

    def candidate?(release, max_of_line, min_line, latest_of_line)
      return false if Gem::Version.new(release.line) < Gem::Version.new(min_line)

      if max_of_line.key?(release.line)
        Gem::Version.new(release.name) > Gem::Version.new(max_of_line[release.line])
      else
        release.name == latest_of_line[release.line]
      end
    end
  end
end
