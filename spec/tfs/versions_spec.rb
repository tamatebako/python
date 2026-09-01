# frozen_string_literal: true

require "tmpdir"

RSpec.describe Tfs::Versions do
  subject(:versions) { described_class.new(File.join(SPEC_FIXTURES, "versions.yml")) }

  it "parses every manifest entry in file order" do
    expect(versions.names).to eq(["3.12.13", "3.12.14", "3.13.15", "9.9.9"])
  end

  it "is enumerable over entries" do
    expect(versions.map(&:name)).to eq(versions.names)
  end

  it "exposes url, sha256 and line of a version" do
    entry = versions.fetch("3.12.14")
    expect(entry.url).to eq("http://127.0.0.1:1/Python-3.12.14.tar.xz")
    expect(entry.sha256).to eq("0000000000000000000000000000000000000000000000000000000000000002")
    expect(entry.line).to eq("3.12")
  end

  it "derives tarball, source-tree and asset names from the version" do
    entry = versions.fetch("9.9.9")
    expect(entry.tarball_name).to eq("Python-9.9.9.tar.xz")
    expect(entry.src_tree_name).to eq("tfs-python-9.9.9-src")
    expect(entry.asset_name).to eq("tfs-python-9.9.9-src.tar.gz")
  end

  it "raises KeyError for a version that is not in the manifest" do
    expect { versions.fetch("1.0.0") }.to raise_error(KeyError, /1\.0\.0/)
  end

  def manifest_with(entry_yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.yml")
      indented = entry_yaml.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join
      File.write(path, "versions:\n#{indented}")
      return described_class.new(path)
    end
  end

  it "rejects a manifest without a top-level versions mapping" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.yml")
      File.write(path, "---\nnot_versions: {}\n")
      expect { described_class.new(path) }.to raise_error(ArgumentError, /versions/)
    end
  end

  it "rejects an entry with a malformed sha256" do
    expect do
      manifest_with(<<~YAML)
        1.2.3:
          url: http://127.0.0.1:1/Python-1.2.3.tar.xz
          sha256: not-hex
          line: "1.2"
      YAML
    end.to raise_error(ArgumentError, /sha256/)
  end

  it "rejects an entry with a malformed version name" do
    expect do
      manifest_with(<<~YAML)
        "1.2":
          url: http://127.0.0.1:1/Python-1.2.tar.xz
          sha256: #{"0" * 64}
          line: "1.2"
      YAML
    end.to raise_error(ArgumentError, /1\.2/)
  end

  it "rejects an entry whose line is not the version's major.minor prefix" do
    expect do
      manifest_with(<<~YAML)
        3.13.15:
          url: http://127.0.0.1:1/Python-3.13.15.tar.xz
          sha256: "#{'0' * 64}"
          line: "3.12"
      YAML
    end.to raise_error(ArgumentError, /prefix/)
  end
end
