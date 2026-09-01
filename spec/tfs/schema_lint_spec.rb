# frozen_string_literal: true

require "tmpdir"

RSpec.describe Tfs::SchemaLint do
  it "validates the repository's versions.yml and every patch manifest" do
    expect(described_class.new.errors).to eq([])
  end

  it "names the offending manifest and rule on a patch-manifest violation" do
    Dir.mktmpdir do |dir|
      bad = File.join(dir, "patch-1.1.yaml")
      File.write(bad, <<~YAML)
        version: "1.1"
        patches:
          - feature: ok_feature
            file: ok_feature.patch
          - file: missing-feature-name.patch
      YAML
      lint = described_class.new(targets: { File.join(Tfs::SchemaLint::SCHEMA_ROOT, "patches.schema.yml") => [bad] })
      expect(lint).not_to be_valid
      expect(lint.errors.first).to include(bad)
    end
  end

  it "names the offending rule on a versions.yml violation" do
    Dir.mktmpdir do |dir|
      bad = File.join(dir, "versions.yml")
      File.write(bad, <<~YAML)
        versions:
          3.13.15:
            url: https://example.test/Python-3.13.15.tar.xz
            sha256: #{"0" * 64}
            line: "3.13"
      YAML
      lint = described_class.new(targets: { File.join(Tfs::SchemaLint::SCHEMA_ROOT, "versions.schema.yml") => [bad] })
      expect(lint).not_to be_valid
      expect(lint.errors.first).to include(bad)
    end
  end
end
