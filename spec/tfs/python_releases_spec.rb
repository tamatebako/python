# frozen_string_literal: true

RSpec.describe Tfs::PythonReleases do
  # A tarball-existence probe stub: the given URLs answer 200, anything
  # else 404s — the shape of Tfs::HttpGet.exists? without the network.
  def probe_publishing(*urls)
    ->(url) { urls.include?(url) }
  end

  def tarball_url(name)
    "https://www.python.org/ftp/python/#{name}/Python-#{name}.tar.xz"
  end

  let(:index_html) { File.read(File.join(SPEC_FIXTURES, "python_index.html")) }
  let(:versions) { Tfs::Versions.new(File.join(SPEC_FIXTURES, "versions.yml")) }

  # Every candidate published EXCEPT 3.15.0: its directory exists (the
  # line's alphas live in it) while its final tarball still 404s — the
  # real python.org state that made the monitor report an unreleased
  # version (issues #3–#13).
  subject(:releases) do
    described_class.new(index_html, tarball_probe: probe_publishing(
                                      tarball_url("3.12.15"), tarball_url("3.14.1"), tarball_url("9.9.10")
                                    ))
  end

  it "parses exact release directories, excluding pre-releases and aliases" do
    expect(releases.names).to eq(%w[2.7.18 3.11.9 3.12.13 3.12.14 3.12.15 3.13.14 3.13.15 3.14.1 3.15.0 9.9.9 9.9.10])
  end

  it "exposes the derived official url and the line of a release" do
    entry = releases.entry("3.13.15")
    expect(entry.url).to eq("https://www.python.org/ftp/python/3.13.15/Python-3.13.15.tar.xz")
    expect(entry.line).to eq("3.13")
  end

  it "raises KeyError for something that was not released" do
    expect { releases.entry("1.2.3") }.to raise_error(KeyError, /1\.2\.3/)
  end

  it "diffs new versions: newer patches of tracked lines and the latest of untracked lines in the window" do
    # 3.12.15 and 9.9.10 patch tracked lines; 3.14.1 is the latest of an
    # untracked line at/above the 3.12 window floor; 3.11.9 is below the
    # window; 3.15.0a1 never parses; 3.15.0's directory exists but its
    # final tarball 404s (pre-release staging) — not reported.
    expect(releases.new_versions(versions).map(&:name)).to eq(%w[3.12.15 3.14.1 9.9.10])
  end

  it "reports a version whose final tarball answers 200" do
    published = described_class.new(index_html, tarball_probe: ->(_url) { true })
    expect(published.new_versions(versions).map(&:name)).to eq(%w[3.12.15 3.14.1 3.15.0 9.9.10])
  end

  it "never reports a pre-release staging directory, noting the skip on stderr" do
    expect { releases.new_versions(versions) }
      .to output(/python 3\.15\.0: skipped — the final tarball is not published yet/).to_stderr
  end

  it "is a no-op when nothing new was released — and never probes" do
    html = <<~HTML
      <pre>
      <a href="3.12.14/">3.12.14/</a>
      <a href="3.13.15/">3.13.15/</a>
      <a href="9.9.9/">9.9.9/</a>
      </pre>
    HTML
    no_probe = ->(url) { raise "unexpected probe of #{url}" }
    expect(described_class.new(html, tarball_probe: no_probe).new_versions(versions)).to eq([])
  end
end
