# frozen_string_literal: true

module ReconEngine
  module LLM
    # A locally served model through Ollama: no API key, no network egress, no
    # per-token cost. The right choice when transaction data can't leave the
    # machine.
    #
    #   ollama pull llama3.1
    #   bin/recon run --provider ollama
    class Ollama < HttpProvider
      def self.default_model = ENV.fetch("RECON_AGENT_MODEL", "llama3.1")

      private

      def endpoint
        "#{ENV.fetch('RECON_OLLAMA_URL', 'http://localhost:11434')}/api/chat"
      end

      def request_body(system, transcript)
        messages = [{ role: "system", content: system }]
        messages += transcript.map { |turn| { role: turn[:role], content: turn[:content] } }
        {
          model: model,
          stream: false,
          format: "json",
          options: { temperature: 0 },
          messages: messages
        }
      end

      def extract_text(payload)
        text = payload.dig("message", "content")
        raise ProviderError, "ollama returned no message content" if text.nil? || text.empty?

        text
      end
    end
  end
end
