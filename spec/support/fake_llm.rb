# frozen_string_literal: true

# A provider that returns scripted responses, so the agent loop can be unit
# tested with no network and no key. Whether a real model behaves well is the
# golden-set evaluation's job.
class FakeLLM < ReconEngine::LLM::Client
  attr_reader :transcripts, :systems

  def initialize(responses:, model: "fake-1", model_backed: true, tokens_per_call: 0)
    super(model: model)
    @tokens_per_call = tokens_per_call
    @responses    = Array(responses)
    @model_backed = model_backed
    @transcripts  = []
    @systems      = []
  end

  def name = "fake"
  def model_backed? = @model_backed
  def calls = @transcripts.length

  def complete(system:, transcript:)
    @systems << system
    @transcripts << transcript.map(&:dup)
    @usage += ReconEngine::LLM::Usage.zero.with(calls: 1, input_tokens: @tokens_per_call)
    raise ReconEngine::ProviderError, "fake provider ran out of scripted responses" if @responses.empty?

    response = @responses.shift
    raise response if response.is_a?(StandardError)

    response
  end

  # Convenience builders so specs read as protocol, not as JSON.
  def self.tool_call(name, arguments = {})
    JSON.generate({ action: "use_tool", tool: name, arguments: arguments })
  end

  def self.classification(classification:, confidence: 0.9, evidence: ["because the tool said so"],
                          explanation: "An explanation long enough to be useful.",
                          suggested_action: "Do the thing.")
    JSON.generate({
                    action: "classify",
                    classification: classification,
                    confidence: confidence,
                    evidence: evidence,
                    explanation: explanation,
                    suggested_action: suggested_action
                  })
  end
end
