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
      tree = prep.prepare("9.9.9", outdir)

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
      expect { prep_with(cache).prepare("9.9.9", File.join(dir, "out")) }
        .to raise_error(Tfs::SourcePrep::DownloadError, /9\.9\.9/)
    end
  end

  it "raises KeyError for a version outside the manifest" do
    Dir.mktmpdir do |dir|
      expect { prep_with(dir).prepare("8.8.8", File.join(dir, "out")) }.to raise_error(KeyError, /8\.8\.8/)
    end
  end
end
