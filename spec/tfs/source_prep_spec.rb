# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"

RSpec.describe Tfs::SourcePrep do
  let(:versions) { Tfs::Versions.new(File.join(SPEC_FIXTURES, "versions.yml")) }

  def prep_with(cache_dir, manifest: versions)
    described_class.new(versions: manifest, cache_dir: cache_dir)
  end

  def seeded_cache(dir)
    cache = File.join(dir, "cache")
    FileUtils.mkdir_p(cache)
    FileUtils.cp(File.join(SPEC_FIXTURES, "Python-9.9.9.tar.xz"), cache)
    cache
  end

  # Builds a tarball of the given tree shape at runtime and a manifest
  # pinning its real sha256 — everything offline, nothing committed twice.
  def runtime_manifest(dir, name, markers: true)
    src = File.join(dir, "Python-#{name}")
    FileUtils.mkdir_p(File.join(src, "sub"))
    File.write(File.join(src, "hello.txt"), "line one\nline two\nline three\n")
    File.write(File.join(src, "sub", "inner.txt"), "inner file, untouched\n")
    if markers
      File.write(File.join(src, "configure"), "#!/bin/sh\n")
      File.write(File.join(src, "Makefile.pre.in"), "# stub\n")
      FileUtils.mkdir_p(File.join(src, "Modules"))
      File.write(File.join(src, "Modules", "getpath.py"), "# stub\n")
    end
    tarball = File.join(dir, "Python-#{name}.tar.xz")
    raise "tar failed" unless system("tar", "-cJf", tarball, "-C", dir, "Python-#{name}")

    path = File.join(dir, "versions.yml")
    File.write(path, <<~YAML)
      versions:
        #{name}:
          url: http://127.0.0.1:1/Python-#{name}.tar.xz
          sha256: "#{Digest::SHA256.file(tarball).hexdigest}"
          line: "#{name.split('.')[0..1].join('.')}"
    YAML
    [Tfs::Versions.new(path), tarball]
  end

  it "fetches from cache, verifies, extracts and stages the tree under its release name" do
    Dir.mktmpdir do |dir|
      prep = prep_with(seeded_cache(dir))
      outdir = File.join(dir, "out")
      tree = prep.prepare("9.9.9", outdir, platform: "linux-gnu")

      expect(tree).to eq(File.join(outdir, "tfs-python-9.9.9-src"))
      expect(File.read(File.join(tree, "hello.txt"))).to eq("line one\nline two\nline three\n")
      expect(File.read(File.join(tree, "sub", "inner.txt"))).to eq("inner file, untouched\n")
      expect(File.exist?(File.join(tree, "Modules", "getpath.py"))).to be(true)
    end
  end

  it "passes the tree-sanity check on a real CPython-shaped tree" do
    Dir.mktmpdir do |dir|
      prep = prep_with(seeded_cache(dir))
      tree = prep.check("9.9.9", File.join(dir, "out"))

      expect(File.basename(tree)).to eq("tfs-python-9.9.9-src")
    end
  end

  it "fails the tree-sanity check, naming the missing marker, on a foreign tree" do
    Dir.mktmpdir do |dir|
      manifest, tarball = runtime_manifest(dir, "8.8.8", markers: false)
      cache = File.join(dir, "cache")
      FileUtils.mkdir_p(cache)
      FileUtils.cp(tarball, File.join(cache, "Python-8.8.8.tar.xz"))

      expect { prep_with(cache, manifest: manifest).check("8.8.8", File.join(dir, "out")) }
        .to raise_error(Tfs::SourcePrep::Error, /8\.8\.8: configure missing/)
    end
  end

  it "rejects a cached tarball whose sha256 does not match the manifest" do
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "cache")
      FileUtils.mkdir_p(cache)
      File.write(File.join(cache, "Python-9.9.9.tar.xz"), "corrupted bytes")

      # the corrupt entry is discarded and re-downloaded; the dead fixture
      # URL (127.0.0.1:1) makes the download fail without any real network
      expect { prep_with(cache).prepare("9.9.9", File.join(dir, "out"), platform: "linux-gnu") }
        .to raise_error(Tfs::SourcePrep::DownloadError, /9\.9\.9/)
    end
  end

  it "raises KeyError for a version outside the manifest" do
    Dir.mktmpdir do |dir|
      expect { prep_with(dir).prepare("8.8.8", File.join(dir, "out"), platform: "linux-gnu") }
        .to raise_error(KeyError, /8\.8\.8/)
    end
  end

  it "refuses a non-default scenario for an unpatched line (named, never a silent pristine fallback)" do
    Dir.mktmpdir do |dir|
      expect { prep_with(seeded_cache(dir)).prepare("9.9.9", File.join(dir, "out"), platform: "windows-msys") }
        .to raise_error(Tfs::SourcePrep::Error, %r{9\.9\.9: scenario windows-msys.*patches/9\.9/ has no patch manifest})
    end
  end

  it "audits nothing for an unpatched line" do
    Dir.mktmpdir do |dir|
      expect(prep_with(seeded_cache(dir)).audit("9.9.9", File.join(dir, "audit"))).to eq([])
    end
  end

  # The patch-applying surface: a runtime-built patch series over the
  # runtime_manifest tree (offline, nothing committed twice).
  context "with a patched line" do
    def write_patch_series(patches_root, line, inner_patch:)
      line_dir = File.join(patches_root, line)
      FileUtils.mkdir_p(line_dir)
      File.write(File.join(line_dir, "hello_txt.patch"), <<~PATCH)
        diff --git a/hello.txt b/hello.txt
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1,3 +1,3 @@
         line one
        -line two
        +line two (patched)
         line three
      PATCH
      File.write(File.join(line_dir, "inner_txt_msys.patch"), inner_patch)
      File.write(File.join(line_dir, "patch-#{line}.yaml"), <<~YAML)
        version: "#{line}"
        patches:
          - feature: hello_txt
            file: hello_txt.patch
          - feature: inner_txt_msys
            file: inner_txt_msys.patch
      YAML
    end

    def good_inner_patch
      <<~PATCH
        diff --git a/sub/inner.txt b/sub/inner.txt
        --- a/sub/inner.txt
        +++ b/sub/inner.txt
        @@ -1 +1 @@
        -inner file, untouched
        +inner file, patched by the msys series
      PATCH
    end

    def patched_prep(dir, version, inner_patch: nil)
      manifest, tarball = runtime_manifest(dir, version)
      cache = File.join(dir, "cache")
      FileUtils.mkdir_p(cache)
      FileUtils.cp(tarball, File.join(cache, "Python-#{version}.tar.xz"))
      line = version.split(".")[0..1].join(".")
      patches_root = File.join(dir, "patches")
      write_patch_series(patches_root, line, inner_patch: inner_patch || good_inner_patch)
      described_class.new(versions: manifest,
                          selection: Tfs::PatchSelection.new(patches_root),
                          cache_dir: cache)
    end

    it "applies the base patch to the linux-gnu tree and not the _msys one" do
      Dir.mktmpdir do |dir|
        tree = patched_prep(dir, "9.9.9").prepare("9.9.9", File.join(dir, "out"), platform: "linux-gnu")
        expect(File.read(File.join(tree, "hello.txt"))).to include("line two (patched)")
        expect(File.read(File.join(tree, "sub", "inner.txt"))).to eq("inner file, untouched\n")
      end
    end

    it "applies the full series to the windows-msys tree" do
      Dir.mktmpdir do |dir|
        tree = patched_prep(dir, "9.9.9").prepare("9.9.9", File.join(dir, "out"), platform: "windows-msys")
        expect(File.read(File.join(tree, "hello.txt"))).to include("line two (patched)")
        expect(File.read(File.join(tree, "sub", "inner.txt"))).to include("patched by the msys series")
      end
    end

    it "audits every selected patch against the pristine tree" do
      Dir.mktmpdir do |dir|
        outcomes = patched_prep(dir, "9.9.9").audit("9.9.9", File.join(dir, "audit"))
        expect(outcomes.map { |outcome| [outcome.patch.feature, outcome.status] })
          .to eq([["hello_txt", :ok], ["inner_txt_msys", :ok]])
      end
    end

    it "reports (never raises) a failed audit outcome naming version and patch" do
      broken = good_inner_patch.sub("inner file, untouched", "content the tree does not carry")
      Dir.mktmpdir do |dir|
        outcomes = patched_prep(dir, "9.9.9", inner_patch: broken).audit("9.9.9", File.join(dir, "audit"))
        failed = outcomes.select(&:failed?)
        expect(failed.size).to eq(1)
        expect(failed.first.detail).to include("FAIL 9.9.9 inner_txt_msys.patch")
      end
    end

    it "raises ApplyError from check when a patch of the line does not apply" do
      broken = good_inner_patch.sub("inner file, untouched", "content the tree does not carry")
      Dir.mktmpdir do |dir|
        expect { patched_prep(dir, "9.9.9", inner_patch: broken).check("9.9.9", File.join(dir, "out")) }
          .to raise_error(Tfs::SourcePrep::ApplyError, /FAIL 9\.9\.9 inner_txt_msys\.patch/)
      end
    end

    it "raises ApplyError when a patch's target is absent from the pristine tree" do
      absent = good_inner_patch.gsub("sub/inner.txt", "sub/absent.txt")
      Dir.mktmpdir do |dir|
        expect { patched_prep(dir, "9.9.9", inner_patch: absent).check("9.9.9", File.join(dir, "out")) }
          .to raise_error(Tfs::SourcePrep::ApplyError, /target sub\/absent\.txt not in the pristine tree/)
      end
    end
  end
end
