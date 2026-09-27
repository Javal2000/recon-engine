# frozen_string_literal: true

module ReconEngine
  module Agent
    # What the agent concluded about one cluster, with its provenance: provider,
    # whether it was model-backed, tool calls, schema repairs, and whether it
    # degraded. That is what separates a reasoned classification from a fallback.
    class Finding < Data.define(:cluster_id, :classification, :confidence, :evidence,
                                :explanation, :suggested_action, :provider, :model,
                                :model_backed, :steps, :tool_calls, :repairs, :degraded, :error, :usage)
      def initialize(usage: LLM::Usage.zero, **fields) = super

      def self.degraded_for(cluster_id, provider:, model:, model_backed:, reason:, steps: 0, tool_calls: 0,
                            repairs: 0, usage: LLM::Usage.zero)
        new(
          cluster_id: cluster_id,
          classification: "UNKNOWN",
          confidence: 0.0,
          evidence: [],
          explanation: "The agent could not classify this cluster: #{reason}",
          suggested_action: "Investigate manually; the deterministic break record above is unaffected.",
          provider: provider,
          model: model,
          model_backed: model_backed,
          steps: steps,
          tool_calls: tool_calls,
          repairs: repairs,
          degraded: true,
          error: reason,
          usage: usage
        )
      end

      def to_report_h
        {
          cluster_id: cluster_id,
          classification: classification,
          confidence: confidence,
          evidence: evidence,
          explanation: explanation,
          suggested_action: suggested_action,
          provenance: {
            provider: provider,
            model: model,
            model_backed: model_backed,
            steps: steps,
            tool_calls: tool_calls,
            schema_repairs: repairs,
            degraded: degraded,
            error: error,
            usage: usage.calls.positive? ? usage.to_report_h : nil
          }.compact
        }
      end
    end
  end
end
