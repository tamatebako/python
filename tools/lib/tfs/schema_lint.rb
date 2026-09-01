# frozen_string_literal: true

require "json_schemer"
require "yaml"

module Tfs
  # Validates versions.yml and every patches/<line>/patch-*.yaml manifest
  # against the JSON Schemas in schema/.
  class SchemaLint
    SCHEMA_ROOT = File.expand_path("../../../schema", __dir__).freeze
    REPO_ROOT = File.expand_path("../../..", __dir__).freeze

    TARGETS = {
      File.join(SCHEMA_ROOT, "versions.schema.yml") => [File.join(REPO_ROOT, "versions.yml")],
      File.join(SCHEMA_ROOT, "patches.schema.yml") => Dir.glob(File.join(REPO_ROOT, "patches", "*", "patch-*.yaml"))
    }.freeze

    def initialize(targets: TARGETS)
      @targets = targets
    end

    # Human-readable violations, each naming the manifest and the schema
    # error. Empty when everything is valid.
    def errors
      @targets.flat_map do |schema_path, manifests|
        schemer = JSONSchemer.schema(YAML.load_file(schema_path))
        manifests.sort.flat_map do |manifest|
          schemer.validate(YAML.load_file(manifest)).map do |problem|
            "#{manifest}: #{problem.fetch("error", problem.to_s)}"
          end
        end
      end
    end

    def valid?
      errors.empty?
    end
  end
end
