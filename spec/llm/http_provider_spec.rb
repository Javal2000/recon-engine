# frozen_string_literal: true

RSpec.describe ReconEngine::LLM::HttpProvider do
  # A provider whose socket and clock are scripted: each call to #perform
  # returns the next queued response, and #pause records the wait instead of
  # sleeping.
  let(:provider_class) do
    Class.new(described_class) do
      attr_reader :pauses
      attr_writer :responses

      def name = "stub"

      private

      def endpoint                            = "https://example.test/v1/generate"
      def request_body(_system, _transcript)  = { prompt: "x" }
      def extract_text(payload)               = payload.fetch("text")
      def usage_from(payload)                 = ReconEngine::LLM::Usage.zero.with(input_tokens: payload.fetch("in", 0))
      def perform(_uri, _body, _headers)      = @responses.shift

      def pause(seconds)
        (@pauses ||= []) << seconds
        @waited_ms = @waited_ms.to_i + (seconds * 1000).round
      end
    end
  end

  let(:provider) { provider_class.new(model: "m") }

  def response(klass, code, body, headers = {})
    klass.new("1.1", code.to_s, "").tap do |r|
      r.instance_variable_set(:@read, true)
      r.instance_variable_set(:@body, body)
      headers.each { |name, value| r[name] = value }
    end
  end

  def ok(text: "done", tokens: 7) = response(Net::HTTPOK, 200, JSON.generate("text" => text, "in" => tokens))

  def rate_limited(retry_delay: nil, headers: {})
    details = if retry_delay
                [{ "@type" => "type.googleapis.com/google.rpc.RetryInfo",
                   "retryDelay" => retry_delay }]
              else
                []
              end
    body = JSON.generate("error" => { "code" => 429, "message" => "Quota exceeded.", "details" => details })
    response(Net::HTTPTooManyRequests, 429, body, headers)
  end

  def complete = provider.complete(system: "s", transcript: [])

  describe "rate limits" do
    it "waits as long as a RetryInfo block in the body says" do
      provider.responses = [rate_limited(retry_delay: "12s"), ok]

      expect(complete).to eq("done")
      expect(provider.pauses).to eq([12.0])
    end

    it "honours a Retry-After header" do
      provider.responses = [rate_limited(headers: { "Retry-After" => "3" }), ok]

      complete
      expect(provider.pauses).to eq([3.0])
    end

    it "caps a very long requested wait" do
      provider.responses = [rate_limited(retry_delay: "86400s"), ok]

      complete
      expect(provider.pauses).to eq([described_class::MAX_WAIT])
    end

    it "falls back to jittered exponential backoff when the server gives no hint" do
      provider.responses = [rate_limited, rate_limited, ok]

      complete
      first, second = provider.pauses
      expect(first).to be_between(1.0, 2.0)
      expect(second).to be_between(2.0, 4.0)
    end

    it "gives up after the attempt budget with the provider's own message" do
      provider.responses = Array.new(described_class::MAX_ATTEMPTS) { rate_limited(retry_delay: "1s") }

      expect { complete }.to raise_error(ReconEngine::ProviderError, "stub: HTTP 429: Quota exceeded.")
      expect(provider.pauses.length).to eq(described_class::MAX_ATTEMPTS - 1)
    end
  end

  describe "quota exhaustion and the circuit breaker" do
    def daily_quota_exhausted
      violation = { "quotaId" => "GenerateRequestsPerDayPerProjectPerModel-FreeTier", "quotaValue" => "20" }
      body = JSON.generate("error" => {
                             "code" => 429, "message" => "You exceeded your current quota.",
                             "details" => [{ "@type" => "type.googleapis.com/google.rpc.QuotaFailure",
                                             "violations" => [violation] },
                                           { "@type" => "type.googleapis.com/google.rpc.RetryInfo",
                                             "retryDelay" => "42s" }]
                           })
      response(Net::HTTPTooManyRequests, 429, body)
    end

    def server_error = response(Net::HTTPServiceUnavailable, 503, JSON.generate("error" => { "message" => "busy" }))

    # Google still sends a short retryDelay with a daily quota error, so the
    # quota id has to decide it, not the delay.
    it "fails at once on a daily quota instead of waiting it out" do
      provider.responses = [daily_quota_exhausted]

      expect { complete }.to raise_error(ReconEngine::QuotaExhausted, /daily quota used up .*limit 20/)
      expect(provider.pauses).to be_nil
    end

    it "stops calling the provider once its quota is gone" do
      provider.responses = [daily_quota_exhausted, ok]
      expect { complete }.to raise_error(ReconEngine::QuotaExhausted)

      expect { complete }.to raise_error(ReconEngine::ProviderError, /not called, its quota ran out/)
      # The queued success was never consumed, so no request went out.
      expect(provider.instance_variable_get(:@responses).length).to eq(1)
    end

    it "opens after consecutive failures and stays open" do
      provider.responses = Array.new(described_class::MAX_ATTEMPTS * described_class::BREAKER_THRESHOLD) do
        server_error
      end
      described_class::BREAKER_THRESHOLD.times { expect { complete }.to raise_error(ReconEngine::ProviderError, /HTTP 503/) }

      expect { complete }.to raise_error(ReconEngine::ProviderError, /not called, 3 calls in a row failed/)
    end

    it "resets the count after a success" do
      failing = Array.new(described_class::MAX_ATTEMPTS) { server_error }
      provider.responses = failing + failing + [ok] + failing + failing + [ok]

      2.times { expect { complete }.to raise_error(ReconEngine::ProviderError) }
      expect(complete).to eq("done")
      2.times { expect { complete }.to raise_error(ReconEngine::ProviderError) }
      expect(complete).to eq("done")
    end
  end

  it "does not retry a client error" do
    provider.responses = [response(Net::HTTPBadRequest, 400, JSON.generate("error" => { "message" => "bad model" }))]

    expect { complete }.to raise_error(ReconEngine::ProviderError, "stub: HTTP 400: bad model")
    expect(provider.pauses).to be_nil
  end

  describe "usage" do
    it "counts each successful call with its tokens" do
      provider.responses = [ok(tokens: 7), ok(tokens: 5)]
      2.times { complete }

      expect(provider.usage.calls).to eq(2)
      expect(provider.usage.input_tokens).to eq(12)
    end

    it "keeps rate-limit waiting separate from time spent in the model" do
      provider.responses = [rate_limited(retry_delay: "4s"), ok]
      complete

      expect(provider.usage.wait_ms).to eq(4_000)
      expect(provider.usage.latency_ms).to be_between(0, 1_000)
    end
  end
end
