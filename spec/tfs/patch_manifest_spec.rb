# frozen_string_literal: true

require "tmpdir"

RSpec.describe Tfs::PatchManifest do
  def manifest_with(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "patch-3.14.yaml")
      File.write(path, yaml)
      return described_class.new(path)
    end
  end

  it "parses the version and the ordered patch entries" do
    manifest = manifest_with(<<~YAML)
      version: "3.14"
      patches:
        - feature: pyport_ms_windows_msys
          file: pyport_ms_windows_msys.patch
        - feature: configure_machdep_msys
          file: configure_machdep_msys.patch
          version: "7"
    YAML

    expect(manifest.version).to eq("3.14")
    expect(manifest.entries.map(&:feature)).to eq(%w[pyport_ms_windows_msys configure_machdep_msys])
    first, second = manifest.entries
    expect(first.whole_line?).to be(true)
    expect(first.exact_for?("7")).to be(false)
    expect(second.whole_line?).to be(false)
    expect(second.exact_for?("7")).to be(true)
    expect(second.exact_for?("8")).to be(false)
  end

  it "rejects a document without the version/patches shape" do
    expect { manifest_with("---\npatches: []\n") }
      .to raise_error(ArgumentError, /expected 'version' string and 'patches' array/)
    expect { manifest_with("---\nversion: \"3.14\"\n") }
      .to raise_error(ArgumentError, /expected 'version' string and 'patches' array/)
  end

  it "rejects an entry with a malformed feature name" do
    expect do
      manifest_with(<<~YAML)
        version: "3.14"
        patches:
          - feature: Not-Snake-Case
            file: ok.patch
      YAML
    end.to raise_error(ArgumentError, /malformed entry/)
  end

  it "rejects an entry with a non-string pin version" do
    expect do
      manifest_with(<<~YAML)
        version: "3.14"
        patches:
          - feature: ok_feature
            file: ok.patch
            version: 7
      YAML
    end.to raise_error(ArgumentError, /malformed entry/)
  end
end
