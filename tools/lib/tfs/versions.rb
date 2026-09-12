# frozen_string_literal: true

require "yaml"

module Tfs
  # Reads versions.yml: the manifest of supported upstream CPython versions.
  # Exposes each version's url / sha256 / line through Entry value objects.
  # A version's +scenarios+ declare which platform scenarios it ships
  # patched-source releases for (subset of SCENARIOS; absent means the
  # linux-gnu scenario only, which is also the unsuffixed back-compat
  # asset and therefore mandatory in every list).
  #
  # The scenario axis arrived with the first patch set (TODO.python/05,
  # the windows-msys port): a scenario tree is the pristine tree plus the
  # scenario's patch set, so the linux-gnu asset stays byte-identical
  # with the pristine upstream tarball while _msys-suffixed patches apply
  # only to the windows-msys tree.
  class Versions
    # One supported CPython version.
    class Entry
      def initialize(name:, url:, sha256:, line:, scenarios:)
        @name = name
        @url = url
        @sha256 = sha256
        @line = line
        @scenarios = scenarios
      end

      attr_reader :name, :url, :sha256, :line, :scenarios

      def tarball_name
        "Python-#{name}.tar.xz"
      end

      def src_tree_name
        "tfs-python-#{name}-src"
      end
    end

    DEFAULT_PATH = File.expand_path("../../../versions.yml", __dir__).freeze
    NAME_FORMAT = /\A\d+\.\d+\.\d+\z/.freeze
    LINE_FORMAT = /\A\d+\.\d+\z/.freeze
    SHA256_FORMAT = /\A[0-9a-f]{64}\z/.freeze

    # Platform scenarios a version may ship, in canonical order.
    SCENARIOS = %w[linux-gnu windows-msys].freeze
    DEFAULT_SCENARIOS = %w[linux-gnu].freeze

    # scenario => release build rows (platform / asset suffix). Unlike
    # the ruby factory there is no pass axis: nothing in the CPython
    # port needs a two-pass tree.
    SCENARIO_BUILDS = {
      "linux-gnu" => [{ platform: "linux-gnu", suffix: "" }].freeze,
      "windows-msys" => [{ platform: "windows-msys", suffix: "-windows-msys" }].freeze
    }.freeze

    include Enumerable

    def initialize(manifest_path = DEFAULT_PATH)
      @entries = parse(manifest_path)
    end

    def each(&block)
      return enum_for(:each) unless block

      @entries.each(&block)
    end

    def names
      @entries.map(&:name)
    end

    def fetch(name)
      entry = @entries.find { |candidate| candidate.name == name }
      raise KeyError, "unknown python version #{name.inspect} (not in versions.yml)" if entry.nil?

      entry
    end

    # The flat (version x scenario build) release matrix: one row per
    # coherent build, e.g. {version: "3.14.7", platform: "windows-msys",
    # suffix: "-windows-msys"}. Consumed by tools/versions --scenarios.
    def builds
      @entries.flat_map do |entry|
        entry.scenarios.flat_map do |scenario|
          SCENARIO_BUILDS.fetch(scenario).map { |build| { version: entry.name, **build } }
        end
      end
    end

    private

    def parse(manifest_path)
      document = YAML.safe_load_file(manifest_path)
      mapping = document.is_a?(Hash) ? document["versions"] : nil
      raise ArgumentError, "#{manifest_path}: expected a top-level 'versions' mapping" unless mapping.is_a?(Hash)

      mapping.map { |name, data| entry(name, data, manifest_path) }
    end

    def entry(name, data, manifest_path)
      unless data.is_a?(Hash)
        raise ArgumentError, "#{manifest_path}: version #{name.inspect} must map url/sha256/line"
      end

      url = data["url"]
      sha256 = data["sha256"]
      line = data["line"]
      scenarios = data.fetch("scenarios", DEFAULT_SCENARIOS)
      validate!(manifest_path, name, url, sha256, line, scenarios)
      Entry.new(name: name, url: url, sha256: sha256, line: line, scenarios: scenarios)
    end

    def validate!(manifest_path, name, url, sha256, line, scenarios)
      unknown = scenarios.is_a?(Array) ? scenarios - SCENARIOS : []
      problem =
        if !name.is_a?(String) || !NAME_FORMAT.match?(name) then "name must look like '3.13.15'"
        elsif !url.is_a?(String) || url.empty? then "url missing"
        elsif !sha256.is_a?(String) || !SHA256_FORMAT.match?(sha256) then "sha256 must be 64 hex chars"
        elsif !line.is_a?(String) || !LINE_FORMAT.match?(line) then "line must look like '3.13'"
        elsif !name.start_with?("#{line}.") then "line must be the major.minor prefix of the version"
        elsif !scenarios.is_a?(Array) || scenarios.empty? then "scenarios must be a non-empty array"
        elsif unknown.any? then "unknown scenarios #{unknown.inspect} (known: #{SCENARIOS.join(', ')})"
        elsif scenarios.uniq.size != scenarios.size then "scenarios must not repeat"
        elsif !scenarios.include?("linux-gnu") then "scenarios must include linux-gnu (unsuffixed back-compat asset)"
        end
      raise ArgumentError, "#{manifest_path}: version #{name.inspect}: #{problem}" if problem
    end
  end
end
