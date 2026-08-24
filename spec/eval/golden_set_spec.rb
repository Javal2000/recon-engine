# frozen_string_literal: true

# Golden-set evaluation for the agent layer.
#
# The generator's manifest is the answer key: every injected fault with the
# classification it should get. This runs the whole pipeline and scores
# per-fault-kind recall against it, as a threshold rather than exact wording.
#
# `rake eval` scores the offline provider, which must be perfect since it is a
# rule table. `RECON_EVAL_PROVIDER=gemini rake eval` scores a real model on the
# same dataset.
RSpec.describe "golden-set evaluation", :eval do
  def self.provider = ENV.fetch("RECON_EVAL_PROVIDER", "offline").to_sym
  def self.seed     = Integer(ENV.fetch("RECON_EVAL_SEED", "42"))
  def self.rows     = Integer(ENV.fetch("RECON_EVAL_ROWS", "600"))

  # Minimum fraction of a fault kind's breaks that must land in a cluster
  # carrying the right classification.
  def thresholds
    { "timing" => 1.0, "rounding" => 1.0, "duplicated" => 1.0, "missing" => 1.0 }
  end

  before(:all) do
    @provider = self.class.provider
    @seed     = self.class.seed
    @rows     = self.class.rows
    @dir      = Dir.mktmpdir("recon-eval")
    @manifest = ReconEngine::Generator.new(seed: @seed, rows: @rows).write(@dir)
    @report   = ReconEngine::Run.call(
      ledger_path: @manifest["paths"]["ledger"],
      warehouse_path: @manifest["paths"]["warehouse"],
      config: ReconEngine::Config.build(agent_provider: @provider, agent_max_clusters: 100)
    )
  end

  after(:all) { FileUtils.remove_entry(@dir) if @dir }

  # Breaks grouped by the classification of the cluster they landed in. A break
  # in an uninvestigated cluster counts as unclassified.
  def breaks_by_classification
    @breaks_by_classification ||= begin
      index = {}
      @report.clusters.each do |cluster|
        label = @report.finding_for(cluster)&.classification || "NOT_INVESTIGATED"
        cluster.break_ids.each { |id| index[id] = label }
      end
      index
    end
  end

  def breaks_of_type(type)
    @report.breaks.select { |b| b.type == type }
  end

  def recall_for(break_type, classification)
    records = breaks_of_type(break_type)
    return 0.0 if records.empty?

    hits = records.count { |b| breaks_by_classification[b.id] == classification }
    (hits.to_f / records.length).round(3)
  end

  it "reports which provider it scored, so a run in CI is unambiguous" do
    expect(@report.findings).not_to be_empty
    warn("\n[eval] provider=#{@provider} model_backed=#{@report.model_backed_agent?} " \
         "seed=#{@seed} rows=#{@rows} clusters=#{@report.clusters.length}")
  end

  describe "the deterministic layer finds what was injected" do
    it "finds every dropped record" do
      expect(breaks_of_type(:missing_in_target).length)
        .to eq(@manifest["fault_counts"]["missing"])
    end

    it "finds every duplicated record" do
      expect(breaks_of_type(:duplicate).length)
        .to eq(@manifest["fault_counts"]["duplicated"])
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
    it "classifies T+1 settlements as timing differences" do
      expect(recall_for(:value_mismatch, "TIMING_DIFFERENCE")).to be > 0
    end

    it "meets the recall threshold for every scored fault kind" do
      scores = {
        "timing" => recall_of_faults("timing", "TIMING_DIFFERENCE"),
        "rounding" => recall_of_faults("rounding", "ROUNDING"),
        "duplicated" => recall_of_faults("duplicated", "DUPLICATE_IN_TARGET"),
        "missing" => recall_of_faults("missing", "MISSING_IN_TARGET")
      }

      warn("[eval] recall #{scores.map { |k, v| "#{k}=#{v}" }.join(' ')}")

      thresholds.each do |kind, threshold|
        expect(scores.fetch(kind)).to be >= threshold,
                                      "#{kind}: expected recall >= #{threshold}, got #{scores.fetch(kind)}"
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

  # Maps a generator fault kind onto the break type it should have produced, then
  # scores the classification of the cluster that break landed in.
  def recall_of_faults(kind, expected_classification)
    break_type = {
      "timing" => :value_mismatch,
      "rounding" => :value_mismatch,
      "duplicated" => :duplicate,
      "missing" => :missing_in_target
    }.fetch(kind)

    band = { "timing" => "date_shifted", "rounding" => "sub_tolerance" }[kind]

    records = breaks_of_type(break_type)
    records = records.select { |b| b.details[:band] == band } if band
    return 0.0 if records.empty?

    hits = records.count { |b| breaks_by_classification[b.id] == expected_classification }
    (hits.to_f / records.length).round(3)
  end
end
