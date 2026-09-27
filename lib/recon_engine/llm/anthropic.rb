# frozen_string_literal: true

module ReconEngine
  module LLM
    # Anthropic Claude via the Messages API.
    #
    #   export ANTHROPIC_API_KEY=...
    #   bin/recon run --provider anthropic --model claude-sonnet-4-5
    #
    # Model names move; override with --model or RECON_AGENT_MODEL rather than
    # editing this file.
    class Anthropic < HttpProvider
      ENDPOINT   = "https://api.anthropic.com/v1/messages"
      API_VERSION = "2023-06-01"

      def self.default_model = ENV.fetch("RECON_AGENT_MODEL", "claude-3-5-haiku-latest")

      private

      def api_key_env = "ANTHROPIC_API_KEY"
      def endpoint    = ENDPOINT

      def request_headers
        {
          "content-type" => "application/json",
          "x-api-key" => api_key,
          "anthropic-version" => API_VERSION
        }
      end

      def request_body(system, transcript)
        {
          model: model,
          max_tokens: 1024,
          temperature: 0,
          system: system,
          messages: transcript.map { |turn| { role: turn[:role], content: turn[:content] } }
        }
      end

      def usage_from(payload)
        usage = payload.fetch("usage", {})
        Usage.zero.with(input_tokens: usage["input_tokens"].to_i, output_tokens: usage["output_tokens"].to_i)
      end

      def extract_text(payload)
        text = payload.fetch("content", []).filter_map { |block| block["text"] }.join
        raise ProviderError, "anthropic returned no text content" if text.empty?

        text
      end
    end
  end
end
