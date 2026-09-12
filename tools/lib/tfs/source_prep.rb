# frozen_string_literal: true

require "digest"
require "fileutils"
require "net/http"
require "open3"
require "uri"

module Tfs
  # Prepares CPython source trees ("tfs-python-<version>-src"): fetch the
  # official tarball (sha256-verified, cached), extract it, then apply the
  # version's patch set for one coherent build scenario with git apply
  # (patches/<line>/, Tfs::PatchSelection — the model ported from
  # tamatebako/ruby per patches/README.md).
  #
  # A line without patches/<line>/patch-<line>.yaml is UNPATCHED: the
  # linux-gnu scenario stages the pristine tree (the pre-patch lines keep
  # working unchanged). Preparing an unpatched line for a non-default
  # scenario (e.g. windows-msys) is a named Error — a scenario without a
  # patch set is a manifest authoring error, never a silent pristine
  # fallback. A patch whose first target file is absent from the pristine
  # tree is likewise a named ApplyError (strict: unlike the ruby factory
  # there is no deferred config.status-shaped target in this port).
  class SourcePrep
    # Base error for every failure raised by SourcePrep.
    class Error < StandardError; end
    # Tarball bytes do not match the manifest sha256.
    class IntegrityError < Error; end
    # Tarball could not be downloaded.
    class DownloadError < Error; end
    # A patch failed git apply / git apply --check, or its target is
    # absent from the pristine tree.
    class ApplyError < Error; end

    # One audit outcome: a patch checked against the pristine tree.
    class Outcome
      def initialize(patch:, status:, detail:)
        @patch = patch
        @status = status
        @detail = detail
      end

      attr_reader :patch, :status, :detail

      def ok?
        @status == :ok
      end

      def failed?
        @status == :failed
      end
    end

    DEFAULT_CACHE_DIR = File.expand_path("../../../.cache/tarballs", __dir__).freeze
    MAX_REDIRECTS = 5

    # Files whose presence makes an extracted tree a CPython source tree
    # (Modules/getpath.py: the frozen runtime prefix resolution the
    # relocatability contract rests on — docs/relocation-probe.md).
    TREE_MARKERS = ["configure", "Makefile.pre.in", File.join("Modules", "getpath.py")].freeze

    def initialize(versions:, selection: nil, cache_dir: DEFAULT_CACHE_DIR)
      @versions = versions
      @selection = selection
      @cache_dir = cache_dir
    end

    # Full pipeline for one coherent build scenario: returns the path of
    # the staged tree (<outdir>/tfs-python-<version>-src) with the
    # scenario's patch set applied.
    def prepare(version_name, outdir, platform:)
      entry = @versions.fetch(version_name)
      src = File.join(outdir, entry.src_tree_name)
      FileUtils.rm_rf(src)
      FileUtils.mv(pristine_tree(version_name, outdir), src)
      patches_for(version_name, platform).each { |patch| apply(src, patch, version_name, []) }
      src
    end

    # Fetch + verify + extract + tree sanity (TREE_MARKERS) + a
    # git apply --check of the line's full patch set when the line is
    # patched. Returns the staged tree path.
    def check(version_name, outdir)
      tree = prepare(version_name, outdir, platform: "linux-gnu")
      TREE_MARKERS.each do |marker|
        next if File.exist?(File.join(tree, marker))

        raise Error, "#{version_name}: #{marker} missing — not a CPython source tree"
      end
      audit(version_name, outdir).each do |outcome|
        raise ApplyError, outcome.detail if outcome.failed?
      end
      tree
    end

    # Per-patch check outcomes against the pristine tree: each selected
    # patch (or an explicitly given set) is tried with git apply --check
    # and reported :ok or :failed, without raising. Empty for an
    # unpatched line — the pristine tree is not re-extracted for nothing.
    def audit(version_name, outdir, patches: nil)
      patches ||= patched_line?(version_name) ? selected_patches(version_name) : []
      return [] if patches.empty?

      tree = pristine_tree(version_name, outdir)
      patches.map do |patch|
        applied = apply(tree, patch, version_name, ["--check"])
        Outcome.new(patch: patch, status: applied ? :ok : :failed, detail: nil)
      rescue ApplyError => e
        Outcome.new(patch: patch, status: :failed, detail: e.message)
      end
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

    # The patch set for one coherent build scenario. An unpatched line
    # (no patches/<line>/ manifest) has an empty set for linux-gnu and a
    # named error for any other scenario.
    def patches_for(version_name, platform)
      return selected_patches(version_name, platform: platform) if patched_line?(version_name)
      return [] if platform == "linux-gnu"

      raise Error, "#{version_name}: scenario #{platform} requested but patches/#{version_name.split('.')[0..1].join('.')}/ has no patch manifest"
    end

    def selected_patches(version_name, platform: nil)
      raise Error, "no patch selection model (Tfs::PatchSelection) configured" if @selection.nil?

      @selection.for(version_name, platform: platform)
    end

    def patched_line?(version_name)
      !@selection.nil? && @selection.line_manifest?(version_name)
    end

    def apply(tree, patch, version_name, extra_args)
      target = File.join(tree, patch.target_file)
      unless File.exist?(target)
        raise ApplyError, "FAIL #{version_name} #{patch.name} (target #{patch.target_file} not in the pristine tree)"
      end

      _out, err, status = Open3.capture3(apply_env(tree), "git", "apply", *extra_args, patch.path, chdir: tree)
      return true if status.success?

      raise ApplyError, "FAIL #{version_name} #{patch.name}\n#{err.strip}"
    end

    # git apply run inside an enclosing git work tree (CI builds under
    # $GITHUB_WORKSPACE) resolves patch paths against that repository's
    # root and silently SKIPS every target -- exit 0, tree untouched.
    # Ceiling discovery at the output directory so git never sees a repo.
    def apply_env(tree)
      { "GIT_CEILING_DIRECTORIES" => File.realpath(File.dirname(tree)) }
    end

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
