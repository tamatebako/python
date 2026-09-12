# frozen_string_literal: true

require "yaml"

module Tfs
  # Parses one patch-<line>[.<patch>].yaml manifest: an ordered array of
  # patch entries. Entry without +version+ applies to the whole line;
  # entry with +version+ applies only to that exact patch level.
  # Ported from tamatebako/ruby (the same model, per patches/README.md).
  class PatchManifest
    # One manifest entry.
    class Entry
      FORMAT = /\A[a-z0-9]+(_[a-z0-9]+)*\z/.freeze

      def initialize(feature:, file:, version:, manifest:)
        @feature = feature
        @file = file
        @version = version
        @manifest = manifest
      end

      attr_reader :feature, :file, :version

      def whole_line?
        @version.nil?
      end

      def exact_for?(patchlevel)
        @version == patchlevel
      end
    end

    def initialize(path)
      document = YAML.safe_load_file(path)
      unless document.is_a?(Hash) && document["version"].is_a?(String) && document["patches"].is_a?(Array)
        raise ArgumentError, "#{path}: expected 'version' string and 'patches' array"
      end

      @version = document["version"]
      @entries = document["patches"].map { |data| entry(path, data) }.freeze
    end

    attr_reader :version, :entries

    private

    def entry(path, data)
      unless data.is_a?(Hash) && data["feature"].is_a?(String) && data["file"].is_a?(String) &&
             Entry::FORMAT.match?(data["feature"]) &&
             (data["version"].nil? || data["version"].is_a?(String))
        raise ArgumentError, "#{path}: malformed entry #{data.inspect}"
      end

      Entry.new(feature: data["feature"], file: data["file"], version: data["version"], manifest: path)
    end
  end
end
