# frozen_string_literal: true

module ReconEngine
  # Every knob that changes the result of a reconciliation, and nowhere else.
  # The run fingerprint covers the input digests plus this config's digest, so a
  # rerun that answers differently did so because an input or a documented
  # setting changed, never because of ambient state or hash iteration order.
  class Config < Data.define(
    :tolerance_cents,      # amounts within +/- this many cents count as equal
    :timing_window_days,   # a record may legitimately appear this many days late
    :max_split_legs,       # upper bound on N in N-to-one matching
    :max_split_candidates, # upper bound on the candidate pool for N-to-one
    :agent_enabled,
    :agent_provider,       # :offline, :gemini, :anthropic, :openai, :ollama
    :agent_model,
    :agent_max_steps,      # tool-loop iterations before the agent gives up
    :agent_max_clusters    # investigate at most this many clusters per run
  )
    DEFAULTS = {
      tolerance_cents: 1,
      timing_window_days: 1,
      max_split_legs: 5,
      max_split_candidates: 12,
      agent_enabled: true,
      agent_provider: :offline,
      agent_model: nil,
      agent_max_steps: 6,
      agent_max_clusters: 40
    }.freeze

    def self.build(**overrides)
      unknown = overrides.keys - DEFAULTS.keys
      raise ArgumentError, "unknown config keys: #{unknown.join(", ")}" unless unknown.empty?

      new(**DEFAULTS, **overrides)
    end

    # Deterministic settings only. Switching the agent on, off, or to another
    # provider must never change which breaks were found (see spec/run_spec.rb).
    def deterministic_digest
      subset = {
        tolerance_cents: tolerance_cents,
        timing_window_days: timing_window_days,
        max_split_legs: max_split_legs,
        max_split_candidates: max_split_candidates
      }
      Digest::SHA256.hexdigest(JSON.generate(subset))[0, 16]
    end

    def agent?
      agent_enabled
    end
  end
end
