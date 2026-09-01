# frozen_string_literal: true

require "tmpdir"

RSpec.describe Tfs::BuildPlan do
  subject(:versions) { Tfs::Versions.new(File.join(SPEC_FIXTURES, "versions.yml")) }

  # A real ReleaseDiff over a fake git: publishing v2, previous release v1.
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

  def versions_from(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "versions.yml")
      File.write(path, yaml)
      return Tfs::Versions.new(path)
    end
  end

  # The fixture manifest, entry for entry (64-hex shas).
  def previous_yaml(sha_31315: "#{"0" * 63}3", with_999: true)
    yaml = <<~YAML
      versions:
        3.12.13:
          url: http://127.0.0.1:1/Python-3.12.13.tar.xz
          sha256: "#{'0' * 63}1"
          line: "3.12"
        3.12.14:
          url: http://127.0.0.1:1/Python-3.12.14.tar.xz
          sha256: "#{'0' * 63}2"
          line: "3.12"
        3.13.15:
          url: http://127.0.0.1:1/Python-3.13.15.tar.xz
          sha256: "#{sha_31315}"
          line: "3.13"
    YAML
    return yaml unless with_999

    yaml + "  9.9.9:\n" \
           "    url: http://127.0.0.1:1/Python-9.9.9.tar.xz\n" \
           "    sha256: \"f9dbc2ef5f74bd9a0f620d2da7cafe1938ad45afa31d0895a2b30b58196f555e\"\n" \
           "    line: \"9.9\"\n"
  end

  let(:previous) { versions_from(previous_yaml) }

  it "builds everything on the first release (no previous tag)" do
    plan = described_class.new(versions: versions, diff: diff_for([], tags: []))
    expect(plan.builds.size).to eq(4)
    expect(plan.copies).to eq([])
  end

  it "requires the previous manifest when a previous tag exists" do
    expect { described_class.new(versions: versions, diff: diff_for([])) }
      .to raise_error(ArgumentError, /previous_versions/)
  end

  context "with a patches/3.12-only change" do
    let(:plan) { described_class.new(versions: versions, diff: diff_for(["patches/3.12/getpath_quirk.patch"]), previous_versions: previous) }

    it "builds only the changed line's versions" do
      expect(plan.builds).to eq([
                                  { version: "3.12.13", tree: "tfs-python-3.12.13-src",
                                    asset: "tfs-python-3.12.13-src.tar.gz" },
                                  { version: "3.12.14", tree: "tfs-python-3.12.14-src",
                                    asset: "tfs-python-3.12.14-src.tar.gz" }
                                ])
    end

    it "copies every other version's asset, named per the release contract" do
      expect(plan.copies).to eq([
                                  { version: "3.13.15", asset: "tfs-python-3.13.15-src.tar.gz" },
                                  { version: "9.9.9", asset: "tfs-python-9.9.9-src.tar.gz" }
                                ])
    end
  end

  it "builds everything on a shared tooling change (correctly full)" do
    plan = described_class.new(versions: versions, diff: diff_for(["tools/prepare"]), previous_versions: previous)
    expect(plan.builds.size).to eq(4)
    expect(plan.copies).to eq([])
  end

  it "builds a version whose versions.yml entry moved, line unchanged" do
    moved = versions_from(previous_yaml(sha_31315: "#{"f" * 64}"))
    plan = described_class.new(versions: versions, diff: diff_for(["versions.yml"]), previous_versions: moved)
    expect(plan.builds.map { |row| row[:version] }).to eq(["3.13.15"])
    expect(plan.copies.map { |row| row[:version] }).to eq(%w[3.12.13 3.12.14 9.9.9])
  end

  it "builds a version that has no previous entry (nothing to copy from)" do
    without = versions_from(previous_yaml(with_999: false))
    plan = described_class.new(versions: versions, diff: diff_for(["versions.yml"]), previous_versions: without)
    expect(plan.builds.map { |row| row[:version] }).to eq(["9.9.9"])
  end

  it "copies the whole set when nothing moved (an idempotent re-publish)" do
    plan = described_class.new(versions: versions, diff: diff_for([]), previous_versions: previous)
    expect(plan.builds).to eq([])
    expect(plan.copies.size).to eq(4)
  end
end
