# frozen_string_literal: true

require "digest"
require "fileutils"
require "net/http"
require "open3"
require "uri"

module Tfs
  # Prepares CPython source trees ("tfs-python-<version>-src"): fetch the
  # official tarball (sha256-verified, cached), extract it, and stage the
  # tree under its release name.
  #
  # The patch inventory is ZERO (patches/README.md): prepare stages the
  # pristine tree unchanged. When the first patch lands, application happens
  # here — between extraction and staging — via the PatchSelection model
  # ported from tamatebako/ruby, and #check gains its git apply --check.
  class SourcePrep
    # Base error for every failure raised by SourcePrep.
    class Error < StandardError; end
    # Tarball bytes do not match the manifest sha256.
    class IntegrityError < Error; end
    # Tarball could not be downloaded.
    class DownloadError < Error; end

    DEFAULT_CACHE_DIR = File.expand_path("../../../.cache/tarballs", __dir__).freeze
    MAX_REDIRECTS = 5

    # Files whose presence makes an extracted tree a CPython source tree
    # (Modules/getpath.py: the frozen runtime prefix resolution the
    # relocatability contract rests on — docs/relocation-probe.md).
    TREE_MARKERS = ["configure", "Makefile.pre.in", File.join("Modules", "getpath.py")].freeze

    def initialize(versions:, cache_dir: DEFAULT_CACHE_DIR)
      @versions = versions
      @cache_dir = cache_dir
    end

    # Full pipeline: returns the path of the staged tree
    # (<outdir>/tfs-python-<version>-src).
    def prepare(version_name, outdir)
      entry = @versions.fetch(version_name)
      src = File.join(outdir, entry.src_tree_name)
      FileUtils.rm_rf(src)
      FileUtils.mv(pristine_tree(version_name, outdir), src)
      src
    end

    # Fetch + verify + extract + tree sanity (TREE_MARKERS). The zero-patch
    # analog of the ruby factory's git-apply lint: proves the pinned
    # url/sha256 pair fetches and unpacks into a CPython source tree.
    # Returns the staged tree path.
    def check(version_name, outdir)
      tree = prepare(version_name, outdir)
      TREE_MARKERS.each do |marker|
        next if File.exist?(File.join(tree, marker))

        raise Error, "#{version_name}: #{marker} missing — not a CPython source tree"
      end
      tree
    end

    # Downloads a tarball URL into the cache (no-op when already cached)
    # and returns [path, sha256]. No manifest verification: used to pin
    # the sha256 of a NEW official release before it enters versions.yml.
    def fetch_tarball(url, file_name)
      FileUtils.mkdir_p(@cache_dir)
      dest = File.join(@cache_dir, file_name)
      download_to(url, dest) unless File.file?(dest)
      [dest, sha256(dest)]
    end

    # Fetch + verify + extract only: returns <outdir>/Python-<version>.
    def pristine_tree(version_name, outdir)
      entry = @versions.fetch(version_name)
      tree = File.join(outdir, "Python-#{entry.name}")
      FileUtils.rm_rf(tree)
      FileUtils.mkdir_p(outdir)
      extract(verified_tarball(entry), outdir)
      raise Error, "#{entry.name}: tarball did not contain Python-#{entry.name}/" unless File.directory?(tree)

      tree
    end

    private

    def verified_tarball(entry)
      FileUtils.mkdir_p(@cache_dir)
      tarball = File.join(@cache_dir, entry.tarball_name)
      return tarball if File.file?(tarball) && sha256(tarball) == entry.sha256

      FileUtils.rm_f(tarball)
      download_to(entry.url, tarball)
      return tarball if sha256(tarball) == entry.sha256

      raise IntegrityError, "#{entry.name}: sha256 mismatch for #{entry.tarball_name} from #{entry.url}"
    end

    def download_to(url, dest)
      uri = URI.parse(url)
      MAX_REDIRECTS.times do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(Net::HTTP::Get.new(uri)) do |response|
            case response
            when Net::HTTPSuccess
              File.open("#{dest}.tmp", "wb") { |file| response.read_body { |chunk| file.write(chunk) } }
              FileUtils.mv("#{dest}.tmp", dest)
              return
            when Net::HTTPRedirection
              uri = URI.parse(response.fetch("location"))
            else
              raise DownloadError, "HTTP #{response.code} from #{uri}"
            end
          end
        end
      end
      raise DownloadError, "too many redirects from #{url}"
    rescue SystemCallError, SocketError, Timeout::Error => e
      raise DownloadError, "cannot download #{uri}: #{e.message}"
    end

    # tar auto-detects the compression (the upstream tarballs are .tar.xz,
    # the spec fixture .tar.gz — the tool accepts either).
    def extract(tarball, outdir)
      _out, err, status = Open3.capture3("tar", "-xf", tarball, "-C", outdir)
      raise Error, "tar failed on #{tarball}: #{err.strip}" unless status.success?
    end

    def sha256(path)
      Digest::SHA256.file(path).hexdigest
    end
  end
end
