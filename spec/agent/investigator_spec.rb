# frozen_string_literal: true

RSpec.describe ReconEngine::Agent::Investigator do
  let(:cfg) { ReconEngine::Config.build(agent_max_steps: 4) }
  let(:ledger_rows)    { ledger(id: "TXN-1", amount: "100.00") }
  let(:warehouse_rows) { [] }
  let(:context)        { context_for(ledger_rows, warehouse_rows, cfg) }
  let(:breaks)         { ReconEngine::Checks::Completeness.new(cfg).call(context) }
  let(:clusters)       { ReconEngine::Breaks::Clusterer.call(breaks) }
  let(:cluster)        { clusters.first }
  let(:tools)          { ReconEngine::Agent::Tools.new(context: context, breaks: breaks) }

  def investigate(responses)
    client = FakeLLM.new(responses: responses)
    finding = described_class.new(client: client, tools: tools, config: cfg).investigate(cluster)
    [finding, client]
  end

  it "returns a finding when the model classifies immediately" do
    finding, client = investigate([FakeLLM.classification(classification: "MISSING_IN_TARGET")])

    expect(finding).to have_attributes(classification: "MISSING_IN_TARGET", degraded: false, steps: 1, tool_calls: 0)
    expect(client.calls).to eq(1)
  end

  it "records what each cluster cost rather than the client's running total" do
    client = FakeLLM.new(responses: Array.new(2) { FakeLLM.classification(classification: "MISSING_IN_TARGET") },
                         tokens_per_call: 10)
    investigator = described_class.new(client: client, tools: tools, config: cfg)

    first  = investigator.investigate(cluster)
    second = investigator.investigate(cluster)

    expect([first.usage.input_tokens, second.usage.input_tokens]).to eq([10, 10])
    expect(client.usage.input_tokens).to eq(20)
  end

  it "keeps the cost of a cluster that degraded" do
    client  = FakeLLM.new(responses: Array.new(20, "not json"), tokens_per_call: 3)
    finding = described_class.new(client: client, tools: tools, config: cfg).investigate(cluster)

    expect(finding.degraded).to be(true)
    expect(finding.usage.calls).to eq(client.calls)
    expect(finding.usage.input_tokens).to eq(3 * client.calls)
  end

  it "reports the progress made before a provider failure, not zeros" do
    finding, = investigate([
                             FakeLLM.tool_call("summarize_cluster", { "break_ids" => cluster.break_ids }),
                             ReconEngine::ProviderError.new("HTTP 503: busy")
                           ])

    expect(finding.degraded).to be(true)
    expect(finding.steps).to eq(1)
    expect(finding.tool_calls).to eq(1)
  end

  it "runs a real loop: tool, observation, tool, observation, classification" do
    finding, client = investigate([
                                    FakeLLM.tool_call("summarize_cluster", { "break_ids" => cluster.break_ids }),
                                    FakeLLM.tool_call("get_schema", { "source" => "ledger" }),
                                    FakeLLM.classification(classification: "MISSING_IN_TARGET")
                                  ])

    expect(finding.tool_calls).to eq(2)
    expect(finding.steps).to eq(3)

    # The final turn's transcript must include both earlier tool results.
    final_transcript = client.transcripts.last.map { |t| t[:content] }.join
    expect(final_transcript).to include("Result of summarize_cluster")
    expect(final_transcript).to include("Result of get_schema")
  end

  it "feeds schema errors back and accepts the corrected reply" do
    finding, client = investigate([
                                    "not json at all",
                                    FakeLLM.classification(classification: "MISSING_IN_TARGET")
                                  ])

    expect(finding.classification).to eq("MISSING_IN_TARGET")
    expect(finding.repairs).to eq(1)
    expect(finding.degraded).to be(false)

    repair_prompt = client.transcripts.last.last[:content]
    expect(repair_prompt).to include("did not satisfy the required schema")
  end

  it "degrades to UNKNOWN rather than raising when the model never complies" do
    finding, = investigate(Array.new(20, "still not json"))

    expect(finding.classification).to eq("UNKNOWN")
    expect(finding.confidence).to eq(0.0)
    expect(finding.degraded).to be(true)
    expect(finding.error).to include("schema-invalid")
  end

  it "degrades when the provider fails outright" do
    client = FakeLLM.new(responses: [ReconEngine::ProviderError.new("HTTP 503. Upstream unavailable")])
    finding = described_class.new(client: client, tools: tools, config: cfg).investigate(cluster)

    expect(finding.degraded).to be(true)
    expect(finding.error).to include("503")
    expect(finding.classification).to eq("UNKNOWN")
  end

  it "stops at the step budget instead of looping forever" do
    responses = Array.new(20) { FakeLLM.tool_call("get_schema", { "source" => "ledger" }) }
    finding, client = investigate(responses)

    expect(client.calls).to eq(cfg.agent_max_steps)
    expect(finding.degraded).to be(true)
    expect(finding.error).to include("step budget")
  end

  it "records provenance on every finding" do
    finding, = investigate([FakeLLM.classification(classification: "MISSING_IN_TARGET")])

    expect(finding.provider).to eq("fake")
    expect(finding.model).to eq("fake-1")
    expect(finding.model_backed).to be(true)
    expect(finding.cluster_id).to eq(cluster.id)
  end

  it "passes the architectural rule to the model in the system prompt" do
    _finding, client = investigate([FakeLLM.classification(classification: "MISSING_IN_TARGET")])

    expect(client.systems.first).to include("The deterministic engine decides what matches")
    expect(client.systems.first).to include("Never re-derive whether two amounts are equal")
  end
end
