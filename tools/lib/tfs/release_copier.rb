# frozen_string_literal: true

require "digest"
require "fileutils"

module Tfs
  # Verified carry-forward of a release asset: download one tarball from a
  # PREVIOUS tamatebako/python release together with that release's
  # published SHA256SUMS, re-verify the bytes against the published sum,
  # and restage tarball + sum file for the new release. The copied bytes
  # stay byte-identical with what the previous release published — never
  # re-packed, never mutated — and a mismatch is a named failure (the
  # download is deleted), never a silently stale or corrupted copy.
  class ReleaseCopier
    # Raised on any copy failure, naming the asset.
    class Error < StandardError; end

    RELEASE_URL = "https://github.com/tamatebako/python/releases/download"

    # tag:     the previous release tag to copy from.
    # fetcher: #call(url) -> String body (Tfs::HttpGet.method(:body) in
    #          production; a stub in specs).
    def initialize(tag, fetcher: HttpGet.method(:body), base_url: RELEASE_URL)
      @tag = tag
      @fetcher = fetcher
      @base_url = "#{base_url}/#{tag}"
    end

    # Copies <asset> (e.g. tfs-python-3.13.15-src.tar.gz) into <dest_dir>
    # and writes <asset>.sha256 next to it — the format release-src's
    # publish job folds into the new release's SHA256SUMS. Returns the
    # verified sha256.
    def copy(asset, dest_dir)
      expected = expected_sha256(asset)
      FileUtils.mkdir_p(dest_dir)
      tarball = File.join(dest_dir, asset)
      File.binwrite(tarball, @fetcher.call("#{@base_url}/#{asset}"))
      actual = Digest::SHA256.file(tarball).hexdigest
      unless actual == expected
        FileUtils.rm_f(tarball)
        raise Error, "#{asset}: sha256 mismatch against release #{@tag}'s published SHA256SUMS " \
                     "(expected #{expected}, got #{actual}); copy refused, download deleted"
      end

      File.write("#{tarball}.sha256", "#{expected}  #{asset}\n")
      expected
    rescue HttpGet::Error => e
      raise Error, "#{asset}: cannot copy from release #{@tag}: #{e.message}"
    end

    private

    def expected_sha256(asset)
      @fetcher.call("#{@base_url}/SHA256SUMS").each_line do |line|
        sha256, file = line.strip.split(/\s+/, 2)
        return sha256.downcase if file&.sub(/\A\*/, "") == asset && sha256.match?(/\A[0-9a-f]{64}\z/i)
      end
      raise Error, "#{asset} not found in the SHA256SUMS of tamatebako/python release #{@tag}"
    end
  end
end
