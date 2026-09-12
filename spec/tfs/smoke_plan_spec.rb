# frozen_string_literal: true

require "tmpdir"

RSpec.describe Tfs::SmokePlan do
  def versions_from(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.yml")
      File.write(path, yaml)
      return Tfs::Versions.new(path)
    end
  end

  # Two lines: 3.13 linux-gnu-only, 3.14 carrying the windows-msys port
  # (the TODO.python/05 catalog shape).
  def catalog
    versions_from(<<~YAML)
      versions:
        3.13.14:
          url: http://127.0.0.1:1/Python-3.13.14.tar.xz
          sha256: "#{'0' * 63}1"
          line: "3.13"
        3.13.15:
          url: http://127.0.0.1:1/Python-3.13.15.tar.xz
          sha256: "#{'0' * 63}2"
          line: "3.13"
        3.14.6:
          url: http://127.0.0.1:1/Python-3.14.6.tar.xz
          sha256: "#{'0' * 63}3"
          line: "3.14"
          scenarios: [linux-gnu, windows-msys]
        3.14.7:
          url: http://127.0.0.1:1/Python-3.14.7.tar.xz
          sha256: "#{'0' * 63}4"
          line: "3.14"
          scenarios: [linux-gnu, windows-msys]
    YAML
  end

  def diff_for(paths, tags: %w[v2 v1])
    git = lambda do |*args|
      case args[0]
      when "tag" then tags.empty? ? "" : "#{tags.join("\n")}\n"
      when "diff" then paths.join("\n")
      else raise Tfs::ReleaseDiff::Error, "unexpected git #{args.join(' ')}"
      end
    end
    Tfs::ReleaseDiff.new("v2", git: git)
  end

  it "smokes every scenario of every line's newest version on the first release" do
    legs = described_class.new(versions: catalog, diff: diff_for([], tags: [])).legs
    expect(legs).to contain_exactly(
      { line: "3.13", version: "3.13.15", platform: "linux-gnu" },
      { line: "3.14", version: "3.14.7", platform: "linux-gnu" },
      { line: "3.14", version: "3.14.7", platform: "windows-msys" }
    )
  end

  it "smokes only the scenarios the changed _msys patches feed" do
    legs = described_class.new(versions: catalog,
                               diff: diff_for(["patches/3.14/pyport_ms_windows_msys.patch"])).legs
    expect(legs).to eq([{ line: "3.14", version: "3.14.7", platform: "windows-msys" }])
  end

  it "smokes every scenario of the line when the line's manifest moves" do
    legs = described_class.new(versions: catalog,
                               diff: diff_for(["patches/3.14/patch-3.14.yaml"])).legs
    expect(legs).to contain_exactly(
      { line: "3.14", version: "3.14.7", platform: "linux-gnu" },
      { line: "3.14", version: "3.14.7", platform: "windows-msys" }
    )
  end

  it "smokes nothing when no patch set changed (the gate is vacuously green)" do
    legs = described_class.new(versions: catalog, diff: diff_for(["tools/prepare", "versions.yml"])).legs
    expect(legs).to eq([])
  end
end
