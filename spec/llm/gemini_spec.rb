# frozen_string_literal: true

RSpec.describe ReconEngine::LLM::Gemini do
  around do |example|
    previous = ENV.fetch("GEMINI_API_KEY", nil)
    ENV["GEMINI_API_KEY"] = "test-key-123"
    example.run
  ensure
    ENV["GEMINI_API_KEY"] = previous
  end

  subject(:client) { described_class.new(model: "gemini-test") }

  it "sends the key in a header, never in the URL" do
    expect(client.send(:endpoint)).not_to include("test-key-123")
    expect(client.send(:endpoint)).not_to include("key=")
    expect(client.send(:request_headers)).to include("x-goog-api-key" => "test-key-123")
  end

  it "calls the model it was given" do
    expect(client.send(:endpoint)).to end_with("/models/gemini-test:generateContent")
  end

  it "fails with a clear message when the key is missing" do
    ENV.delete("GEMINI_API_KEY")

    expect { client.send(:request_headers) }
      .to raise_error(ReconEngine::ProviderError, /GEMINI_API_KEY is not set/)
  end
end
