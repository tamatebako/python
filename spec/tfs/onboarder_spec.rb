# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"

RSpec.describe Tfs::Onboarder do
  let(:releases) { Tfs::PythonReleases.new(File.read(File.join(SPEC_FIXTURES, "python_index.html"))) }

  # Builds a tarball of a CPython-shaped (or deliberately marker-less) tree
  # at runtime, so nothing touches the network and no sha is committed twice.
  def build_tarball(dir, version, markers: true)
    src = File.join(dir, "Python-#{version}")
    FileUtils.mkdir_p(File.join(src, "sub"))
    File.write(File.join(src, "hello.txt"), "line one\nline two\nline three\n")
    if markers
      File.write(File.join(src, "configure"), "#!/bin/sh\n")
      File.write(File.join(src, "Makefile.pre.in"), "# stub\n")
      FileUtils.mkdir_p(File.join(src, "Modules"))
      File.write(File.join(src, "Modules", "getpath.py"), "# stub\n")
    end
    tarball = File.join(dir, "Python-#{version}.tar.xz")
    raise "tar failed" unless system("tar", "-cJf", tarball, "-C", dir, "Python-#{version}")

    tarball
  end

  # A scratch repo (versions.yml from the fixture) plus a cache seeded with
  # the tarball the onboard would download.
  def onboard_in(dir, version, markers: true)
    FileUtils.cp(File.join(SPEC_FIXTURES, "versions.yml"), File.join(dir, "versions.yml"))
    cache = File.join(dir, "cache")
    FileUtils.mkdir_p(cache)
    tarball = build_tarball(dir, version, markers: markers)
    FileUtils.cp(tarball, File.join(cache, "Python-#{version}.tar.xz"))
    described_class.new(releases: releases, repo_root: dir, cache_dir: cache).onboard(version)
  end

  it "pins the new version into versions.yml and verifies it" do
    Dir.mktmpdir do |dir|
      result = onboard_in(dir, "9.9.10")

      expect(result).to be_verified
      expect(result.error).to be_nil
      expect(result.written).to eq([File.join(dir, "versions.yml")])

      text = File.read(File.join(dir, "versions.yml"))
      entry = Tfs::Versions.new(File.join(dir, "versions.yml")).fetch("9.9.10")
      expect(entry.url).to eq("https://www.python.org/ftp/python/9.9.10/Python-9.9.10.tar.xz")
      expect(entry.sha256).to eq(Digest::SHA256.file(File.join(dir, "Python-9.9.10.tar.xz")).hexdigest)
      expect(entry.line).to eq("9.9")
      # sorted append: after 9.9.9, at the end of the fixture list
      expect(text.index("  9.9.9:")).to be < text.index("  9.9.10:")
    end
  end

  it "inserts a new patch of a tracked line in sorted position, mid-list" do
    Dir.mktmpdir do |dir|
      result = onboard_in(dir, "3.12.15")

      expect(result).to be_verified
      text = File.read(File.join(dir, "versions.yml"))
      expect(text.index("  3.12.14:")).to be < text.index("  3.12.15:")
      expect(text.index("  3.12.15:")).to be < text.index("  3.13.15:")
      expect(Tfs::Versions.new(File.join(dir, "versions.yml")).fetch("3.12.15").line).to eq("3.12")
    end
  end

  it "fails named and restores versions.yml when the fetched tree is not CPython" do
    Dir.mktmpdir do |dir|
      original = File.read(File.join(SPEC_FIXTURES, "versions.yml"))
      result = onboard_in(dir, "9.9.10", markers: false)

      expect(result).not_to be_verified
      expect(result.error).to include("9.9.10").and include("configure")
      expect(result.written).to eq([])
      expect(File.read(File.join(dir, "versions.yml"))).to eq(original)
    end
  end

  it "fails named and restores versions.yml when the tarball cannot be fetched" do
    Dir.mktmpdir do |dir|
      original = File.read(File.join(SPEC_FIXTURES, "versions.yml"))
      FileUtils.cp(File.join(SPEC_FIXTURES, "versions.yml"), File.join(dir, "versions.yml"))
      result = described_class.new(releases: releases, repo_root: dir, cache_dir: File.join(dir, "cache")).onboard("9.9.10")

      expect(result).not_to be_verified
      expect(result.error).to include("9.9.10").or include("127.0.0.1")
      expect(File.read(File.join(dir, "versions.yml"))).to eq(original)
    end
  end

  it "fails named for a version that is not an official release" do
    Dir.mktmpdir do |dir|
      FileUtils.cp(File.join(SPEC_FIXTURES, "versions.yml"), File.join(dir, "versions.yml"))
      result = described_class.new(releases: releases, repo_root: dir, cache_dir: File.join(dir, "cache")).onboard("1.2.3")

      expect(result).not_to be_verified
      expect(result.error).to include("1.2.3")
    end
  end

  it "re-verifying an already pinned version writes nothing" do
    Dir.mktmpdir do |dir|
      FileUtils.cp(File.join(SPEC_FIXTURES, "versions.yml"), File.join(dir, "versions.yml"))
      cache = File.join(dir, "cache")
      FileUtils.mkdir_p(cache)
      FileUtils.cp(File.join(SPEC_FIXTURES, "Python-9.9.9.tar.xz"), cache)

      result = described_class.new(releases: releases, repo_root: dir, cache_dir: cache).onboard("9.9.9")

      expect(result).to be_verified
      expect(result.written).to eq([])
    end
  end

  it "inherits the line's scenario coverage when onboarding a new patch release" do
    Dir.mktmpdir do |dir|
      fixture = File.read(File.join(SPEC_FIXTURES, "versions.yml"))
      File.write(File.join(dir, "versions.yml"),
                 fixture.sub("    line: \"9.9\"\n", "    line: \"9.9\"\n    scenarios: [linux-gnu, windows-msys]\n"))
      cache = File.join(dir, "cache")
      FileUtils.mkdir_p(cache)
      tarball = build_tarball(dir, "9.9.10")
      FileUtils.cp(tarball, File.join(cache, "Python-9.9.10.tar.xz"))
      result = described_class.new(releases: releases, repo_root: dir, cache_dir: cache).onboard("9.9.10")

      expect(result).to be_verified
      text = File.read(File.join(dir, "versions.yml"))
      entry = text[/^  9\.9\.10:\n(?:^    .*\n)+/]
      expect(entry).to include("scenarios: [linux-gnu, windows-msys]")
      expect(Tfs::Versions.new(File.join(dir, "versions.yml")).fetch("9.9.10").scenarios)
        .to eq(%w[linux-gnu windows-msys])
    end
  end

  it "keeps the default implicit when the line has no scenario declaration" do
    Dir.mktmpdir do |dir|
      result = onboard_in(dir, "9.9.10")

      expect(result).to be_verified
      expect(File.read(File.join(dir, "versions.yml"))).not_to include("scenarios:")
    end
  end
end
