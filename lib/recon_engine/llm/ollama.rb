# frozen_string_literal: true

module ReconEngine
  module LLM
    # A locally served model through Ollama: no API key, no network egress, no
    # per-token cost. The right choice when transaction data can't leave the
    # machine.
    #
    #   ollama pull llama3.1:8b
    #   bin/recon run --provider ollama
    class Ollama < HttpProvider
      # Ollama gives a model a small context window unless asked, and silently
      # drops the start of a longer prompt, which is where the rules are. An
      # investigation grows with every tool result, so it asks for room.
      CONTEXT_TOKENS = 8192

      # A local model split between GPU and CPU can take minutes on a long
      # prompt, and timing out only restarts the same work from scratch.
      LOCAL_READ_TIMEOUT = 300

      def self.default_model = ENV.fetch("RECON_AGENT_MODEL", "llama3.1:8b")

      private

      def endpoint
        "#{ENV.fetch("RECON_OLLAMA_URL", "http://localhost:11434")}/api/chat"
      end

      def read_timeout = LOCAL_READ_TIMEOUT

      def request_body(system, transcript)
        messages = [{ role: "system", content: system }]
        messages += transcript.map { |turn| { role: turn[:role], content: turn[:content] } }
        {
          model: model,
          stream: false,
          format: "json",
          options: { temperature: 0, num_ctx: CONTEXT_TOKENS },
          messages: messages
        }
      end

      def usage_from(payload)
        Usage.zero.with(input_tokens: payload["prompt_eval_count"].to_i, output_tokens: payload["eval_count"].to_i)
      end

      def extract_text(payload)
        text = payload.dig("message", "content")
        raise ProviderError, "ollama returned no message content" if text.nil? || text.empty?

        text
      end
    end
  end
end
