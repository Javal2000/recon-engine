# frozen_string_literal: true

# The request each hosted provider builds and how it reads the reply. The
# network itself is covered in http_provider_spec; this pins the wire format.
RSpec.describe "LLM providers" do
  let(:transcript) { [{ role: "user", content: "hi" }, { role: "assistant", content: "{}" }] }

  around do |example|
    keys = %w[GEMINI_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY]
    previous = keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    keys.each { |key| ENV[key] = "test-#{key}" }
    example.run
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def body(klass) = klass.new(model: "m").send(:request_body, "SYSTEM", transcript)
  def text(klass, payload) = klass.new(model: "m").send(:extract_text, payload)
  def headers(klass) = klass.new(model: "m").send(:request_headers)

  describe ReconEngine::LLM::Gemini do
    it "sends the system prompt separately and names the assistant 'model'" do
      request = body(described_class)

      expect(request[:system_instruction]).to eq(parts: [{ text: "SYSTEM" }])
      expect(request[:contents].map { |c| c[:role] }).to eq(%w[user model])
      expect(request[:generationConfig]).to include(temperature: 0, responseMimeType: "application/json")
    end

    it "reports a blocked prompt instead of returning nothing" do
      expect { text(described_class, "promptFeedback" => { "blockReason" => "SAFETY" }) }
        .to raise_error(ReconEngine::ProviderError, /blocked: SAFETY/)
    end
  end

  describe ReconEngine::LLM::Anthropic do
    it "authenticates with x-api-key and a pinned API version" do
      expect(headers(described_class))
        .to include("x-api-key" => "test-ANTHROPIC_API_KEY", "anthropic-version" => anything)
    end

    it "sends the system prompt as its own field" do
      expect(body(described_class)).to include(system: "SYSTEM", temperature: 0, messages: transcript)
    end

    it "joins text blocks and rejects an empty reply" do
      expect(text(described_class, "content" => [{ "type" => "text", "text" => "a" }, { "text" => "b" }])).to eq("ab")
      expect { text(described_class, "content" => []) }.to raise_error(ReconEngine::ProviderError)
    end
  end

  describe ReconEngine::LLM::OpenAI do
    it "authenticates with a bearer token and asks for a JSON object" do
      expect(headers(described_class)).to include("authorization" => "Bearer test-OPENAI_API_KEY")
      expect(body(described_class)).to include(response_format: { type: "json_object" })
    end

    it "puts the system prompt first in the message list" do
      expect(body(described_class)[:messages].first).to eq(role: "system", content: "SYSTEM")
    end

    it "rejects a reply with no content" do
      expect { text(described_class, "choices" => [{ "message" => { "content" => "" } }]) }
        .to raise_error(ReconEngine::ProviderError)
    end
  end

  describe ReconEngine::LLM::Ollama do
    it "needs no key and asks for JSON without streaming" do
      expect(body(described_class)).to include(stream: false, format: "json")
      expect(headers(described_class)).not_to have_key("authorization")
    end

    it "reads the message content" do
      expect(text(described_class, "message" => { "content" => "{}" })).to eq("{}")
      expect { text(described_class, {}) }.to raise_error(ReconEngine::ProviderError)
    end
  end
end
