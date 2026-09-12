# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Tfs::PatchSelection do
  PATCH_BODY = <<~PATCH.freeze
    diff --git a/__TARGET__ b/__TARGET__
    --- a/__TARGET__
    +++ b/__TARGET__
    @@ -1 +1 @@
    -line
    +patched
  PATCH

  # PatchSelection reads manifests lazily (at #for time), so the scratch
  # patches root must outlive the helper: every example runs inside one.
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  # A runtime-built patches root: line dir + patch-<line>.yaml (+ optional
  # overlay), every manifest entry backed by a real .patch file.
  def patches_root_with(base_entries, overlay_entries = nil, line: "3.14", overlay_version: "3.14.7")
    line_dir = File.join(@dir, "patches", line)
    FileUtils.mkdir_p(line_dir)
    (base_entries + (overlay_entries || [])).each do |entry|
      File.write(File.join(line_dir, entry[:file]), PATCH_BODY.gsub("__TARGET__", entry[:target]))
    end
    write_manifest(File.join(line_dir, "patch-#{line}.yaml"), line, base_entries)
    write_manifest(File.join(line_dir, "patch-#{overlay_version}.yaml"), overlay_version, overlay_entries) if overlay_entries
    described_class.new(File.join(@dir, "patches"))
  end

  def write_manifest(path, version, entries)
    File.open(path, "w") do |file|
      file.puts "version: \"#{version}\""
      file.puts "patches:"
      entries.each do |entry|
        file.puts "  - feature: #{entry[:feature]}"
        file.puts "    file: #{entry[:file]}"
        file.puts "    version: \"#{entry[:version]}\"" if entry[:version]
      end
    end
  end

  def entry(feature, file: "#{feature}.patch", target: "hello.txt", version: nil)
    { feature: feature, file: file, target: target, version: version }
  end

  it "resolves the base manifest's entries in order" do
    selection = patches_root_with([entry("one_msys"), entry("two_msys")])
    expect(selection.for("3.14.7").map(&:feature)).to eq(%w[one_msys two_msys])
  end

  it "raises SelectionError for a line without a manifest" do
    patches_root_with([entry("one_msys")], line: "3.14")
    expect { described_class.new(File.join(@dir, "patches")).for("3.13.15") }
      .to raise_error(Tfs::PatchSelection::SelectionError, /no patch manifest/)
  end

  describe "#line_manifest?" do
    it "answers per line without raising" do
      selection = patches_root_with([entry("one_msys")], line: "3.14")
      expect(selection.line_manifest?("3.14.7")).to be(true)
      expect(selection.line_manifest?("3.13.15")).to be(false)
    end
  end

  describe "the overlay" do
    it "supersedes a base feature for the overlay's exact patch level only" do
      selection = patches_root_with(
        [entry("fix_msys")],
        [entry("fix_msys", file: "fix_msys_7.patch", target: "inner.txt", version: "7")]
      )
      expect(selection.for("3.14.7").map(&:name)).to eq(["fix_msys_7.patch"])
      expect(selection.for("3.14.8").map(&:name)).to eq(["fix_msys.patch"])
    end

    it "appends overlay-only features" do
      selection = patches_root_with(
        [entry("fix_msys")],
        [entry("extra_msys", version: "7")]
      )
      expect(selection.for("3.14.7").map(&:feature)).to eq(%w[fix_msys extra_msys])
    end
  end

  it "raises SelectionError when a feature's versioned entries do not cover the patch level" do
    selection = patches_root_with([entry("fix_msys", version: "7")])
    expect { selection.for("3.14.9") }
      .to raise_error(Tfs::PatchSelection::SelectionError, /fix_msys.*no entry covering patch level 9/)
  end

  describe "platform narrowing" do
    # A base patch and an _msys patch targeting the SAME file: the msys
    # variant replaces the neutral one on windows (the ruby factory's
    # platform-override dedup).
    let(:selection) do
      patches_root_with([
                          entry("hello_txt", target: "hello.txt"),
                          entry("hello_txt_msys", target: "hello.txt"),
                          entry("other_msys", target: "other.txt")
                        ])
    end

    it "linux-gnu drops the _msys set, keeping the base patches" do
      expect(selection.for("3.14.7", platform: "linux-gnu").map(&:feature)).to eq(%w[hello_txt])
    end

    it "windows-msys keeps the _msys set and the complementing base patches" do
      expect(selection.for("3.14.7", platform: "windows-msys").map(&:feature)).to eq(%w[hello_txt_msys other_msys])
    end

    it "rejects an unknown platform" do
      expect { selection.for("3.14.7", platform: "plan9") }.to raise_error(ArgumentError, /unknown platform/)
    end
  end

  describe "Tfs::PatchSelection::Patch" do
    it "parses the first target file from the +++ b/ header" do
      selection = patches_root_with([entry("one_msys", target: "deep/nested/file.c")])
      expect(selection.for("3.14.7").first.target_file).to eq("deep/nested/file.c")
    end

    it "carries the patch-level pin (nil for whole-line entries)" do
      selection = patches_root_with([entry("one_msys"), entry("two_msys", version: "7")])
      line_wide, pinned = selection.for("3.14.7")
      expect(line_wide.line_wide?).to be(true)
      expect(pinned.line_wide?).to be(false)
      expect(pinned.patchlevel).to eq("7")
    end
  end
end
