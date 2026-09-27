# frozen_string_literal: true

RSpec.describe ReconEngine::Run do
  let(:dir) { Dir.mktmpdir }
  let(:manifest) { ReconEngine::Generator.new(seed: 42, rows: 400).write(dir) }
  let(:ledger_path)    { manifest["paths"]["ledger"] }
  let(:warehouse_path) { manifest["paths"]["warehouse"] }

  after { FileUtils.remove_entry(dir) }

  def investigator_for(report, client)
    context = ReconEngine::Checks::Context.new(
      config: report.config, match_result: report.match_result,
      ledger_profile: report.ledger_profile, warehouse_profile: report.warehouse_profile,
      ledger_rows: [], warehouse_rows: []
    )
    tools = ReconEngine::Agent::Tools.new(context: context, breaks: report.breaks)
    ReconEngine::Agent::Investigator.new(client: client, tools: tools, config: report.config)
  end

  def reconcile(**overrides)
    described_class.call(
      ledger_path: ledger_path,
      warehouse_path: warehouse_path,
      config: ReconEngine::Config.build(**overrides)
    )
  end

  describe "idempotency" do
    # Same bytes in, same fingerprint out.
    it "produces an identical fingerprint on a rerun" do
      first, second = Array.new(2) { reconcile }

      expect(second.deterministic_fingerprint).to eq(first.deterministic_fingerprint)
    end

    it "produces identical break ids on a rerun" do
      first, second = Array.new(2) { reconcile }

      expect(second.breaks.map(&:id)).to eq(first.breaks.map(&:id))
    end

    it "produces identical cluster ordering on a rerun" do
      first, second = Array.new(2) { reconcile }

      expect(second.clusters.map(&:id)).to eq(first.clusters.map(&:id))
    end

    # Turning the agent on must not change a single deterministic conclusion.
    it "is unaffected by whether the agent ran" do
      with_agent    = reconcile(agent_enabled: true)
      without_agent = reconcile(agent_enabled: false)

      expect(with_agent.deterministic_fingerprint).to eq(without_agent.deterministic_fingerprint)
      expect(with_agent.breaks.map(&:id)).to eq(without_agent.breaks.map(&:id))
      expect(without_agent.findings).to be_empty
    end

    it "changes the fingerprint when a documented setting changes" do
      tight = reconcile(tolerance_cents: 0)
      loose = reconcile(tolerance_cents: 5)

      expect(tight.deterministic_fingerprint).not_to eq(loose.deterministic_fingerprint)
    end

    it "changes the fingerprint when the input bytes change" do
      baseline = reconcile
      File.write(warehouse_path, "#{File.read(warehouse_path)}TXN-999999,ACC-0001,2026-01-05,1.00,USD,POSTED\n")

      expect(reconcile.deterministic_fingerprint).not_to eq(baseline.deterministic_fingerprint)
    end
  end

  describe "the report" do
    subject(:report) { reconcile }

    it "explains every aggregate cluster from the row-level breaks and keeps it from the agent" do
      aggregates = report.clusters.reject(&:row_level?).select(&:attribution)

      expect(aggregates).not_to be_empty
      expect(aggregates).to all(be_explained)
      expect(report.findings.map(&:cluster_id)).not_to include(*aggregates.map(&:id))
      expect(report.classification_summary).to include("EXPLAINED")
    end

    it "finds the faults the generator injected" do
      expect(report.breaks_by_type).to include("missing_in_target", "duplicate", "value_mismatch")
      expect(report.break_count).to be > 0
    end

    it "does not report the rows that were only made harder to match" do
      # composite_only and split rows should reconcile cleanly; if they show up
      # as breaks, the matcher regressed.
      expect(report.match_result.strategy_counts).to include(:composite, :split)
    end

    it "excludes aggregate breaks from the headline dollar impact" do
      row_level = report.breaks.select(&:row_level?).sum { |b| b.magnitude_cents.abs }

      expect(report.row_level_impact_cents).to eq(row_level)
      expect(report.breaks.map(&:level)).to include(:aggregate)
    end

    it "reconciles a file against itself cleanly" do
      clean = described_class.call(
        ledger_path: ledger_path, warehouse_path: ledger_path,
        config: ReconEngine::Config.build(agent_enabled: false)
      )

      expect(clean).to be_clean
      expect(clean.breaks).to be_empty
    end
  end

  describe "partial failure" do
    it "still reports every break when the agent provider cannot be built" do
      degraded = reconcile(agent_provider: :nonexistent_provider)
      baseline = reconcile(agent_enabled: false)

      expect(degraded.breaks.map(&:id)).to eq(baseline.breaks.map(&:id))
      expect(degraded.findings).to all(satisfy(&:degraded))
      expect(degraded.findings.first.classification).to eq("UNKNOWN")
    end

    it "still reports every break when a provider errors mid-run" do
      exploding = Class.new(ReconEngine::LLM::Client) do
        def name = "exploding"
        def complete(**) = raise(ReconEngine::ProviderError, "boom")
      end

      report  = reconcile(agent_enabled: false)
      finding = investigator_for(report, exploding.new).investigate(report.clusters.first)

      expect(finding.degraded).to be(true)
      expect(finding.error).to include("boom")
    end
  end

  describe "the offline provider" do
    subject(:report) { reconcile(agent_provider: :offline) }

    it "labels itself as not model-backed" do
      expect(report.findings).not_to be_empty
      expect(report.model_backed_agent?).to be(false)
      expect(ReconEngine::Reporting::CliReport.new(report, color: false).render)
        .to include("scripted stand-in")
    end

    it "reaches its classifications through the real tool loop" do
      expect(report.findings.reject(&:degraded)).to all(satisfy { |f| f.tool_calls.positive? })
    end
  end

  describe "the JSON report" do
    it "round-trips through JSON and carries the fingerprint" do
      report  = reconcile
      payload = JSON.parse(ReconEngine::Reporting::JsonReport.generate(report))

      expect(payload.dig("run", "deterministic_fingerprint")).to eq(report.deterministic_fingerprint)
      expect(payload["breaks"].length).to eq(report.break_count)
      expect(payload["clusters"].first).to include("finding")
      expect(payload.dig("agent", "model_backed")).to be(false)
    end

    it "is identical between runs apart from the timing block" do
      first  = JSON.parse(ReconEngine::Reporting::JsonReport.generate(reconcile))
      second = JSON.parse(ReconEngine::Reporting::JsonReport.generate(reconcile))

      expect(first.except("run")).to eq(second.except("run"))
    end
  end
end
