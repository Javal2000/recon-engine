# frozen_string_literal: true

RSpec.describe ReconEngine::LLM::Usage do
  let(:zero) { described_class.zero }

  it "adds and subtracts field by field" do
    a = zero.with(calls: 2, input_tokens: 100, thinking_tokens: 40)
    b = zero.with(calls: 1, input_tokens: 30, output_tokens: 5)

    expect((a + b).to_h).to include(calls: 3, input_tokens: 130, output_tokens: 5, thinking_tokens: 40)
    expect((a - b).to_h).to include(calls: 1, input_tokens: 70)
  end

  it "counts thinking tokens in the total" do
    expect(zero.with(input_tokens: 10, output_tokens: 5, thinking_tokens: 120).total_tokens).to eq(135)
  end

  # Each provider names these fields differently; the payloads below are
  # trimmed copies of the real response shapes.
  describe "parsing provider responses" do
    def usage_for(klass, payload) = klass.new(model: "m").send(:usage_from, payload)

    it "reads Gemini's usageMetadata, including thoughts" do
      usage = usage_for(ReconEngine::LLM::Gemini, "usageMetadata" => {
                          "promptTokenCount" => 12, "candidatesTokenCount" => 5, "thoughtsTokenCount" => 133
                        })

      expect(usage.to_h).to include(input_tokens: 12, output_tokens: 5, thinking_tokens: 133)
    end

    it "reads Anthropic's usage block" do
      usage = usage_for(ReconEngine::LLM::Anthropic, "usage" => { "input_tokens" => 40, "output_tokens" => 9 })

      expect(usage.to_h).to include(input_tokens: 40, output_tokens: 9, thinking_tokens: 0)
    end

    it "splits OpenAI's reasoning tokens out of the completion count" do
      usage = usage_for(ReconEngine::LLM::OpenAI, "usage" => {
                          "prompt_tokens" => 50, "completion_tokens" => 300,
                          "completion_tokens_details" => { "reasoning_tokens" => 256 }
                        })

      expect(usage.to_h).to include(input_tokens: 50, output_tokens: 44, thinking_tokens: 256)
    end

    it "reads Ollama's eval counts" do
      usage = usage_for(ReconEngine::LLM::Ollama, "prompt_eval_count" => 70, "eval_count" => 20)

      expect(usage.to_h).to include(input_tokens: 70, output_tokens: 20)
    end

    it "treats a response without usage as zero rather than failing" do
      expect(usage_for(ReconEngine::LLM::Gemini, {})).to eq(zero)
    end
  end
end
