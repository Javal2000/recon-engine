# frozen_string_literal: true

module ReconEngine
  module LLM
    # OpenAI via the Chat Completions API.
    #
    #   export OPENAI_API_KEY=...
    #   bin/recon run --provider openai --model gpt-4o-mini
    class OpenAI < HttpProvider
      ENDPOINT = "https://api.openai.com/v1/chat/completions"

      def self.default_model = ENV.fetch("RECON_AGENT_MODEL", "gpt-4o-mini")

      private

      def api_key_env = "OPENAI_API_KEY"
      def endpoint    = ENDPOINT

      def request_headers
        {
          "content-type" => "application/json",
          "authorization" => "Bearer #{api_key}"
        }
      end

      def request_body(system, transcript)
        messages = [{ role: "system", content: system }]
        messages += transcript.map { |turn| { role: turn[:role], content: turn[:content] } }
        {
          model: model,
          temperature: 0,
          response_format: { type: "json_object" },
          messages: messages
        }
      end

      # completion_tokens already includes reasoning tokens, so they are split out
      # rather than counted twice.
      def usage_from(payload)
        usage     = payload.fetch("usage", {})
        reasoning = usage.dig("completion_tokens_details", "reasoning_tokens").to_i
        Usage.zero.with(input_tokens: usage["prompt_tokens"].to_i,
                        output_tokens: usage["completion_tokens"].to_i - reasoning,
                        thinking_tokens: reasoning)
      end

      def extract_text(payload)
        text = payload.dig("choices", 0, "message", "content")
        raise ProviderError, "openai returned no message content" if text.nil? || text.empty?

        text
      end
    end
  end
end
