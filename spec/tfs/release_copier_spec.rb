# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"

RSpec.describe Tfs::ReleaseCopier do
  let(:content) { "fake source tarball bytes\0with binary" }
  let(:sha256) { Digest::SHA256.hexdigest(content) }
  let(:asset) { "tfs-python-3.13.15-src.tar.gz" }
  let(:base) { "https://example.test/dl/v0.1.1" }

  # A fetcher stub serving the given url => body map, 404ing anything else
  # like the real Tfs::HttpGet.
  def copier_serving(bodies)
    described_class.new("v0.1.1", base_url: "https://example.test/dl", fetcher: lambda { |url|
      bodies.fetch(url) { raise Tfs::HttpGet::Error, "HTTP 404 from #{url}" }
    })
  end

  def mirror(sums_line)
    { "#{base}/SHA256SUMS" => "#{sums_line}\n", "#{base}/#{asset}" => content }
  end

  it "copies the asset byte-identical and writes the sha256 sidecar" do
    Dir.mktmpdir do |dir|
      verified = copier_serving(mirror("#{sha256}  #{asset}")).copy(asset, dir)
      expect(verified).to eq(sha256)
      expect(File.binread(File.join(dir, asset))).to eq(content)
      expect(File.read(File.join(dir, "#{asset}.sha256"))).to eq("#{sha256}  #{asset}\n")
    end
  end

  it "accepts the sha256sum binary-mode marker and an uppercase sum" do
    Dir.mktmpdir do |dir|
      verified = copier_serving(mirror("#{sha256.upcase} *#{asset}")).copy(asset, dir)
      expect(verified).to eq(sha256)
    end
  end

  it "refuses a corrupted download, naming the asset, and deletes it" do
    Dir.mktmpdir do |dir|
      expect { copier_serving(mirror("#{"0" * 64}  #{asset}")).copy(asset, dir) }
        .to raise_error(Tfs::ReleaseCopier::Error, /#{Regexp.escape(asset)}: sha256 mismatch.*copy refused/)
      expect(File.exist?(File.join(dir, asset))).to be(false)
      expect(File.exist?(File.join(dir, "#{asset}.sha256"))).to be(false)
    end
  end

  it "fails loudly, naming the asset, when it is absent from SHA256SUMS" do
    Dir.mktmpdir do |dir|
      expect { copier_serving(mirror("#{sha256}  tfs-python-3.12.14-src.tar.gz")).copy(asset, dir) }
        .to raise_error(Tfs::ReleaseCopier::Error, /#{Regexp.escape(asset)} not found in the SHA256SUMS.*v0\.1\.1/)
    end
  end

  it "wraps a fetch failure naming the asset and the release" do
    Dir.mktmpdir do |dir|
      expect { copier_serving({}).copy(asset, dir) }
        .to raise_error(Tfs::ReleaseCopier::Error, /#{Regexp.escape(asset)}: cannot copy from release v0\.1\.1: HTTP 404/)
    end
  end
end
