# frozen_string_literal: true

module ReconEngine
  module LLM
    # Google Gemini via the Generative Language API.
    #
    #   export GEMINI_API_KEY=...            # aistudio.google.com, free tier
    #   bin/recon run --provider gemini
    #
    # temperature 0 and responseMimeType JSON let the provider constrain its own
    # output, which is cheaper than catching the failure downstream. Schema
    # validation and retry still exist, because cheaper is not guaranteed.
    #
    # Google retires model versions regularly, so the default is pinned and
    # RECON_AGENT_MODEL or --model overrides it.
    class Gemini < HttpProvider
      BASE = "https://generativelanguage.googleapis.com/v1beta/models"

      def self.default_model = ENV.fetch("RECON_AGENT_MODEL", "gemini-3.8-flash")

      private

      def api_key_env = "GEMINI_API_KEY"

      # The key goes in a header rather than the query string, so it never ends
      # up in a URL that a proxy or an error trace might log.
      def endpoint
        "#{BASE}/#{model}:generateContent"
      end

      def request_headers
        super.merge("x-goog-api-key" => api_key)
      end

      def request_body(system, transcript)
        {
          system_instruction: { parts: [{ text: system }] },
          contents: transcript.map do |turn|
            { role: turn[:role] == "assistant" ? "model" : "user", parts: [{ text: turn[:content] }] }
          end,
          generationConfig: { temperature: 0, responseMimeType: "application/json" }
        }
      end

      def extract_text(payload)
        text = payload.dig("candidates", 0, "content", "parts", 0, "text")
        return text unless text.nil?

        blocked = payload.dig("promptFeedback", "blockReason")
        raise ProviderError, "gemini returned no text#{blocked ? " (blocked: #{blocked})" : ''}"
      end
    end
  end
end
