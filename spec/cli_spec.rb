# frozen_string_literal: true

require "stringio"

RSpec.describe ReconEngine::CLI do
  let(:dir) { Dir.mktmpdir }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:manifest) { ReconEngine::Generator.new(seed: 3, rows: 200).write(File.join(dir, "data")) }

  after { FileUtils.remove_entry(dir) }

  def cli(*argv) = described_class.new(argv, stdout: stdout, stderr: stderr).run

  def reconcile(ledger, warehouse, *extra)
    cli("run", "--ledger", ledger, "--warehouse", warehouse, "--quiet", *extra)
  end

  # The exit codes are what a scheduler acts on, so each one is pinned here.
  describe "exit codes" do
    it "returns 0 when the two files reconcile" do
      ledger = manifest["paths"]["ledger"]

      expect(reconcile(ledger, ledger)).to eq(described_class::EXIT_CLEAN)
    end

    it "returns 1 when breaks are found" do
      expect(reconcile(manifest["paths"]["ledger"], manifest["paths"]["warehouse"])).to eq(described_class::EXIT_BREAKS)
    end

    it "returns 2 and says why when a required option is missing" do
      expect(cli("run", "--warehouse", "x.csv")).to eq(described_class::EXIT_ERROR)
      expect(stderr.string).to include("--ledger is required")
    end

    it "returns 2 for a file that does not exist" do
      expect(reconcile(File.join(dir, "nope.csv"), manifest["paths"]["warehouse"])).to eq(described_class::EXIT_ERROR)
      expect(stderr.string).to include("does not exist")
    end

    it "returns 2 for an unknown command or option" do
      expect(cli("reconcile")).to eq(described_class::EXIT_ERROR)
      expect(cli("run", "--no-such-flag")).to eq(described_class::EXIT_ERROR)
    end
  end

  it "writes the JSON report when asked" do
    path = File.join(dir, "out", "report.json")
    reconcile(manifest["paths"]["ledger"], manifest["paths"]["warehouse"], "--json", path)

    expect(JSON.parse(File.read(path))).to include("run", "summary", "clusters", "breaks")
  end

  it "prints the human report unless --quiet" do
    cli("run", "--ledger", manifest["paths"]["ledger"], "--warehouse", manifest["paths"]["warehouse"], "--no-agent")

    expect(stdout.string).to include("RECONCILIATION REPORT", "MATCHING", "agent        disabled")
  end

  it "generates data and prints the manifest summary" do
    expect(cli("generate", "--dir", File.join(dir, "gen"), "--rows", "100", "--seed", "5")).to eq(0)
    expect(JSON.parse(stdout.string)).to include("fault_counts", "paths")
  end

  it "runs the evaluation and writes both outputs" do
    json = File.join(dir, "eval.json")
    md   = File.join(dir, "eval.md")

    expect(cli("eval", "--rows", "200", "--json", json, "--markdown", md)).to eq(0)
    expect(stdout.string).to include("| **all** |", "coverage 100%")
    expect(JSON.parse(File.read(json))).to include("overall_recall" => 1.0)
    expect(File.read(md)).to start_with("| Fault | Expected |")
  end

  it "prints help and the version" do
    expect(cli("help")).to eq(0)
    expect(cli("version")).to eq(0)
    expect(stdout.string).to include("USAGE", "recon-engine #{ReconEngine::VERSION}")
  end
end
