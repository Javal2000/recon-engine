# frozen_string_literal: true

module ReconEngine
  module LLM
    # The one interface the agent layer knows about. Above it the tool loop,
    # schema validation and retry are provider-agnostic; below it is HTTP
    # plumbing. That boundary is why the agent can be tested against a fake, and
    # why swapping Gemini for Ollama is a flag rather than a refactor.
    class Client
      REGISTRY = {
        offline: "ReconEngine::LLM::Offline",
        gemini: "ReconEngine::LLM::Gemini",
        anthropic: "ReconEngine::LLM::Anthropic",
        openai: "ReconEngine::LLM::OpenAI",
        ollama: "ReconEngine::LLM::Ollama"
      }.freeze

      def self.build(config)
        provider  = config.agent_provider.to_sym
        const_name = REGISTRY.fetch(provider) do
          raise ProviderError, "unknown provider #{provider.inspect}; expected one of #{REGISTRY.keys.join(', ')}"
        end
        Object.const_get(const_name).new(model: config.agent_model)
      end

      attr_reader :model

      def initialize(model: nil)
        @model = model || self.class.default_model
      end

      def self.default_model = nil

      def name = self.class.name.split("::").last.downcase

      # @param system [String] instructions that do not change between turns
      # @param transcript [Array<Hash>] [{role: "user"|"assistant", content: String}]
      # @return [String] the raw model output, unparsed
      def complete(system:, transcript:)
        raise NotImplementedError, "#{self.class}#complete"
      end

      # False for the offline stand-in; reports print it next to every finding.
      def model_backed? = true
    end
  end
end
