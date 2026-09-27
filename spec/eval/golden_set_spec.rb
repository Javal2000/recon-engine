# frozen_string_literal: true

# Golden-set evaluation for the agent layer.
#
# The generator's manifest is the answer key: every injected fault with the
# classification it should get. This runs the whole pipeline and scores each
# fault kind's recall with ReconEngine::Evaluation, as a threshold rather than
# exact wording.
#
# `rake eval` scores the offline provider, which must be perfect since it is a
# rule table. `RECON_EVAL_PROVIDER=gemini rake eval` scores a real model on the
# same dataset against a lower bar.
RSpec.describe "golden-set evaluation", :eval do
  def self.provider = ENV.fetch("RECON_EVAL_PROVIDER", "offline").to_sym
  def self.seed     = Integer(ENV.fetch("RECON_EVAL_SEED", "42"))
  def self.rows     = Integer(ENV.fetch("RECON_EVAL_ROWS", "600"))

  MODEL_RECALL_THRESHOLD = 0.8

  before(:all) do
    @dir        = Dir.mktmpdir("recon-eval")
    @manifest   = ReconEngine::Generator.new(seed: self.class.seed, rows: self.class.rows).write(@dir)
    @report     = ReconEngine::Run.call(
      ledger_path: @manifest["paths"]["ledger"],
      warehouse_path: @manifest["paths"]["warehouse"],
      config: ReconEngine::Config.build(agent_provider: self.class.provider, agent_max_clusters: 100)
    )
    @evaluation = ReconEngine::Evaluation.new(manifest: @manifest, report: @report)
  end

  after(:all) { FileUtils.remove_entry(@dir) if @dir }

  def threshold = @report.model_backed_agent? ? MODEL_RECALL_THRESHOLD : 1.0

  it "reports which provider it scored, so a run in CI is unambiguous" do
    summary = @evaluation.to_h
    warn("\n[eval] provider=#{summary[:provider]} models=#{summary[:models].join(',')} " \
         "clusters=#{summary[:clusters_investigated]}/#{summary[:clusters]} coverage=#{summary[:coverage]}")
    expect(@report.findings).not_to be_empty
  end

  describe "the deterministic layer finds what was injected" do
    it "finds every dropped record" do
      expect(@report.breaks.count { |b| b.type == :missing_in_target }).to eq(@manifest["fault_counts"]["missing"])
    end

    it "finds every duplicated record" do
      expect(@report.breaks.count { |b| b.type == :duplicate }).to eq(@manifest["fault_counts"]["duplicated"])
    end

    it "scores exactly one break for every injected fault that should produce one" do
      scored = @evaluation.recall_by_kind.transform_values { |row| row[:breaks] }
      expect(scored).to eq(@manifest["fault_counts"].slice(*ReconEngine::Evaluation::SCORED.keys))
    end

    it "does not invent breaks for rows that were only made harder to match" do
      # composite_only rows have no transaction id downstream; split rows arrive
      # as three legs. Both must reconcile silently.
      strategies = @report.match_result.strategy_counts
      expect(strategies[:composite]).to be >= @manifest["fault_counts"]["composite_only"]
      expect(strategies[:split]).to eq(@manifest["fault_counts"]["split"])
    end
  end

  describe "the agent explains what the deterministic layer found" do
    it "meets the recall threshold for every fault kind" do
      by_kind = @evaluation.recall_by_kind
      warn("[eval] recall #{by_kind.map { |kind, row| "#{kind}=#{row[:recall]}" }.join(' ')} " \
           "overall=#{@evaluation.overall_recall}")

      by_kind.each do |kind, row|
        expect(row[:recall]).to be >= threshold, "#{kind}: expected recall >= #{threshold}, got #{row[:recall]}"
      end
    end

    it "never fabricates a classification outside the documented enum" do
      classifications = @report.findings.map(&:classification)

      expect(classifications).to all(satisfy { |c| ReconEngine::Agent::Schema::CLASSIFICATIONS.include?(c) })
    end

    it "grounds every non-degraded finding in at least one tool call" do
      expect(@report.findings.reject(&:degraded)).to all(satisfy { |f| f.tool_calls.positive? })
    end
  end
end
