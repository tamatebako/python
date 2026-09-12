# frozen_string_literal: true

require "open3"

module Tfs
  # The diff model behind release-src's rebuild decisions: what changed
  # between the previous release tag and the tag being published (or HEAD
  # when that tag does not exist yet — a manual dispatch ahead of tagging;
  # everything when there is no previous tag).
  #
  # A version's source tarball is a function of exactly these inputs:
  #
  # * patches/<line>/**  — the line's patch set (a PER-LINE input, with a
  #                        per-scenario attribution: #changed_scenarios)
  # * versions.yml       — the version's own url/sha256/line entry
  #                        (a PER-VERSION input)
  # * tools/**, schema/**, workflows — the shared machinery: a change
  #                        rebuilds EVERY version, correctly
  #
  # Any other changed path cannot be attributed by construction, so it
  # counts as shared too (fail closed: an unrecognized input rebuilds the
  # full matrix rather than shipping possibly-stale verified copies).
  #
  # Slimmed from tamatebako/ruby's ReleaseDiff: no pass axis (the ruby
  # factory's msys GNUmakefile two-pass has no CPython analog).
  class ReleaseDiff
    # Release tags (v*), newest first.
    TAG_LIST_ARGS = %w[tag --list v* --sort=-version:refname].freeze

    LINE_PATH = %r{\Apatches/(\d+\.\d+)/}.freeze
    VERSIONS_MANIFEST = "versions.yml"

    # Raised on any git failure (named — never a silent fallback).
    class Error < StandardError; end

    # The production git runner: #call(*args) -> stdout, raises Error on
    # failure. Specs inject a fake responding to #call the same way.
    class Git
      def call(*args)
        out, err, status = Open3.capture3("git", *args)
        raise Error, "git #{args.join(' ')} failed: #{err.strip}" unless status.success?

        out
      end
    end

    def initialize(tag, git: Git.new)
      raise Error, "a release tag is required" if tag.nil? || tag.to_s.empty?

      @tag = tag
      @git = git
    end

    # The release tag immediately older than the one being published — the
    # diff base, and the copy source for unchanged versions. Nil when there
    # is no older release tag (the first release builds everything).
    def previous_tag
      return @previous_tag if defined?(@previous_tag)

      tags = release_tags
      @previous_tag =
        if tags.include?(@tag)
          tags[(tags.index(@tag) + 1)..]&.first
        else
          tags.first
        end
    end

    # "<previous>..<tag>" for a published tag, "<previous>..HEAD" ahead of
    # tagging; nil when there is no previous tag.
    def range
      previous_tag && "#{previous_tag}..#{release_tags.include?(@tag) ? @tag : 'HEAD'}"
    end

    # Paths changed in the range; empty on the first release.
    def changed_paths
      @changed_paths ||=
        if range.nil?
          []
        else
          @git.call("diff", "--name-only", range).lines.map(&:strip).reject(&:empty?)
        end
    end

    # Lines whose patch set changed. Nil means "every line" (no previous
    # tag — build everything). Empty while no patch folder changed.
    def patch_lines
      return nil if previous_tag.nil?

      changed_paths.filter_map { |path| path[LINE_PATH, 1] }.uniq
    end

    # Lines whose patch set changed, mapped to the scenarios the changed
    # patches FEED (the fault-isolation axis the smoke plan and the
    # build/copy plan share):
    #
    # * a patch-*.yaml manifest change feeds EVERY scenario of the line
    #   (selection rules moved — nothing narrower is knowable);
    # * a _msys-suffixed patch feeds the windows-msys scenario only;
    # * anything else (a base patch, an unrecognized shape) fails closed:
    #   every scenario.
    #
    # Nil means "no previous tag" (every scenario of every line). A line
    # the diff saw but cannot attribute is the BuildPlan/SmokePlan layer's
    # fail-closed case, not this layer's.
    def changed_scenarios
      return nil if previous_tag.nil?

      changed_paths.each_with_object({}) do |path, acc|
        m = path.match(%r{\Apatches/(\d+\.\d+)/(.+)})
        next unless m

        line, name = m.captures
        acc[line] ||= []
        acc[line] |= scenario_attribution(name)
      end
    end

    # A shared input changed (or there is no previous tag): every version
    # rebuilds. Only patches/<line>/** and versions.yml are attributable
    # inputs; anything else — tools/**, schema/**, workflows, a patches/
    # file outside a line directory — is shared by construction.
    def shared_change?
      return true if previous_tag.nil?

      changed_paths.any? { |path| shared_path?(path) }
    end

    # versions.yml changed at all (per-entry comparison in Tfs::BuildPlan
    # decides which versions actually rebuild).
    def versions_manifest_changed?
      return true if previous_tag.nil?

      changed_paths.include?(VERSIONS_MANIFEST)
    end

    # A file's content at the previous release tag (the previous
    # versions.yml feeding the per-entry comparison).
    def previous_file(path)
      raise Error, "no previous release tag — nothing to read #{path} from" if previous_tag.nil?

      @git.call("show", "#{previous_tag}:#{path}")
    end

    private

    def release_tags
      @release_tags ||= @git.call(*TAG_LIST_ARGS).lines.map(&:strip).reject(&:empty?)
    end

    def shared_path?(path)
      !(path.match?(LINE_PATH) || path == VERSIONS_MANIFEST)
    end

    # A terminal _msys (optionally patch-versioned, the ruby factory's
    # _msys_<N>.patch convention) marks a windows-msys-only patch.
    SCENARIO_SUFFIX = /_msys(?:_\d+)?\.patch\z/.freeze

    # One patch path's scenario attribution (the class doc's rules).
    def scenario_attribution(name)
      return Tfs::Versions::SCENARIOS if name.end_with?(".yaml")
      return ["windows-msys"] if name.match?(SCENARIO_SUFFIX)

      # A base patch: every scenario; an unrecognized suffix shape is a
      # manifest authoring error the lint gate owns — attribute wide.
      Tfs::Versions::SCENARIOS
    end
  end
end
