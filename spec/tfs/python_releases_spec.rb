# frozen_string_literal: true

RSpec.describe Tfs::PythonReleases do
  subject(:releases) { described_class.new(File.read(File.join(SPEC_FIXTURES, "python_index.html"))) }

  let(:versions) { Tfs::Versions.new(File.join(SPEC_FIXTURES, "versions.yml")) }

  it "parses exact release directories, excluding pre-releases and aliases" do
    expect(releases.names).to eq(%w[2.7.18 3.11.9 3.12.13 3.12.14 3.12.15 3.13.14 3.13.15 3.14.1 9.9.9 9.9.10])
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
    # window; 3.15.0a1 is a pre-release (never parsed).
    expect(releases.new_versions(versions).map(&:name)).to eq(%w[3.12.15 3.14.1 9.9.10])
  end

  it "is a no-op when nothing new was released" do
    html = <<~HTML
      <pre>
      <a href="3.12.14/">3.12.14/</a>
      <a href="3.13.15/">3.13.15/</a>
      <a href="9.9.9/">9.9.9/</a>
      </pre>
    HTML
    expect(described_class.new(html).new_versions(versions)).to eq([])
  end
end
