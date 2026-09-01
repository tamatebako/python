# frozen_string_literal: true

require "yaml"

module Tfs
  # Reads versions.yml: the manifest of supported upstream CPython versions.
  # Exposes each version's url / sha256 / line through Entry value objects.
  #
  # Unlike the ruby factory there is NO scenario axis today: with a zero
  # patch inventory (patches/README.md) the staged tree is identical for
  # every platform, so each version ships exactly one src tarball. A
  # platform-conditional patch introduces scenarios here (SCENARIOS +
  # per-entry lists, as in tamatebako/ruby) together with the patch itself.
  class Versions
    # One supported CPython version.
    class Entry
      def initialize(name:, url:, sha256:, line:)
        @name = name
        @url = url
        @sha256 = sha256
        @line = line
      end

      attr_reader :name, :url, :sha256, :line

      def tarball_name
        "Python-#{name}.tar.xz"
      end

      def src_tree_name
        "tfs-python-#{name}-src"
      end

      def asset_name
        "#{src_tree_name}.tar.gz"
      end
    end

    DEFAULT_PATH = File.expand_path("../../../versions.yml", __dir__).freeze
    NAME_FORMAT = /\A\d+\.\d+\.\d+\z/.freeze
    LINE_FORMAT = /\A\d+\.\d+\z/.freeze
    SHA256_FORMAT = /\A[0-9a-f]{64}\z/.freeze

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
      validate!(manifest_path, name, url, sha256, line)
      Entry.new(name: name, url: url, sha256: sha256, line: line)
    end

    def validate!(manifest_path, name, url, sha256, line)
      problem =
        if !name.is_a?(String) || !NAME_FORMAT.match?(name) then "name must look like '3.13.15'"
        elsif !url.is_a?(String) || url.empty? then "url missing"
        elsif !sha256.is_a?(String) || !SHA256_FORMAT.match?(sha256) then "sha256 must be 64 hex chars"
        elsif !line.is_a?(String) || !LINE_FORMAT.match?(line) then "line must look like '3.13'"
        elsif !name.start_with?("#{line}.") then "line must be the major.minor prefix of the version"
        end
      raise ArgumentError, "#{manifest_path}: version #{name.inspect}: #{problem}" if problem
    end
  end
end
