# frozen_string_literal: true

RSpec.describe Tfs::ReleaseDiff do
  # Fake git runner keyed on argv, in the shape ReleaseDiff calls it.
  def fake_git(tags:, diffs: {}, shows: {})
    lambda do |*args|
      case args[0]
      when "tag"
        tags.empty? ? "" : "#{tags.join("\n")}\n"
      when "diff"
        diffs.fetch(args[2]) { raise Tfs::ReleaseDiff::Error, "git diff --name-only #{args[2]} failed: unexpected range" }
      when "show"
        shows.fetch(args[1]) { raise Tfs::ReleaseDiff::Error, "git show #{args[1]} failed: not found" }
      else
        raise Tfs::ReleaseDiff::Error, "unexpected git #{args.join(' ')}"
      end
    end
  end

  let(:tags) { %w[v0.1.2 v0.1.1 v0.1.0] }

  it "requires a tag" do
    expect { described_class.new("") }.to raise_error(Tfs::ReleaseDiff::Error, /tag is required/)
  end

  describe "previous tag and range" do
    it "diffs an existing tag against the immediately older release tag" do
      diff = described_class.new("v0.1.1", git: fake_git(tags: tags))
      expect(diff.previous_tag).to eq("v0.1.0")
      expect(diff.range).to eq("v0.1.0..v0.1.1")
    end

    it "has no previous tag for the oldest release" do
      diff = described_class.new("v0.1.0", git: fake_git(tags: tags))
      expect(diff.previous_tag).to be_nil
      expect(diff.range).to be_nil
    end

    it "diffs HEAD against the newest tag when the tag does not exist yet (dispatch ahead of tagging)" do
      diff = described_class.new("v0.1.3", git: fake_git(tags: tags))
      expect(diff.previous_tag).to eq("v0.1.2")
      expect(diff.range).to eq("v0.1.2..HEAD")
    end

    it "treats the first-ever release as everything-changed" do
      diff = described_class.new("v0.0.1", git: fake_git(tags: []))
      expect(diff.previous_tag).to be_nil
      expect(diff.patch_lines).to be_nil
      expect(diff.shared_change?).to be(true)
      expect(diff.versions_manifest_changed?).to be(true)
    end
  end

  describe "change classification" do
    def diff_with(paths)
      described_class.new("v0.1.2", git: fake_git(tags: tags, diffs: { "v0.1.1..v0.1.2" => paths.join("\n") }))
    end

    it "maps patches/<line>/ paths to their line, once" do
      diff = diff_with(["patches/3.13/getpath_quirk.patch", "patches/3.13/other.patch", "patches/3.12/x.patch"])
      expect(diff.patch_lines).to eq(%w[3.13 3.12])
      expect(diff.shared_change?).to be(false)
    end

    it "sees versions.yml as a per-version input, never shared" do
      diff = diff_with(["versions.yml"])
      expect(diff.patch_lines).to eq([])
      expect(diff.versions_manifest_changed?).to be(true)
      expect(diff.shared_change?).to be(false)
    end

    it "treats the shared tooling trees as changing every version" do
      ["tools/prepare", "tools/lib/tfs/source_prep.rb", "schema/versions.schema.yml"].each do |path|
        expect(diff_with([path]).shared_change?).to be(true), "expected #{path} to be a shared change"
      end
    end

    it "fails closed on paths it cannot attribute to a line (rebuilds every version)" do
      ["README.md", ".github/workflows/release-src.yml", "patches/README.md", "Gemfile.lock"].each do |path|
        expect(diff_with([path]).shared_change?).to be(true), "expected #{path} to be a shared change"
      end
    end

    it "reports no changes on an empty diff (re-run of an unchanged tree)" do
      diff = diff_with([])
      expect(diff.patch_lines).to eq([])
      expect(diff.shared_change?).to be(false)
      expect(diff.versions_manifest_changed?).to be(false)
    end
  end

  describe "#previous_file" do
    it "reads a file at the previous release tag" do
      git = fake_git(tags: tags, shows: { "v0.1.1:versions.yml" => "versions: {}\n" })
      expect(described_class.new("v0.1.2", git: git).previous_file("versions.yml")).to eq("versions: {}\n")
    end

    it "raises when there is no previous tag" do
      expect { described_class.new("v0.1.0", git: fake_git(tags: tags)).previous_file("versions.yml") }
        .to raise_error(Tfs::ReleaseDiff::Error, /no previous release tag/)
    end
  end
end
