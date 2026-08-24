# frozen_string_literal: true

module ReconEngine
  module Agent
    # The agent loop: the model picks a tool, reads the result, decides what to
    # look at next, and stops when it can justify a classification. Bounded by a
    # step budget, a repair budget, and tools that cannot mutate anything.
    #
    # Any failure in here (provider outage, invalid JSON, a tool raising)
    # degrades this cluster to UNKNOWN and lets the run finish. The breaks are
    # already computed by the time this runs.
    class Investigator
      MAX_REPAIRS_PER_STEP = 1

      def initialize(client:, tools:, config:)
        @client = client
        @tools  = tools
        @config = config
      end

      def investigate(cluster)
        transcript = [{ role: "user", content: Prompt.initial(cluster, @tools) }]
        steps      = 0
        repairs    = 0
        tool_calls = 0

        attempts     = 0
        max_steps    = @config.agent_max_steps
        max_repairs  = MAX_REPAIRS_PER_STEP * max_steps
        max_attempts = max_steps + max_repairs

        # Two separate budgets, because a step and a repair are different
        # failures. Burning the step budget means the model is investigating and
        # not converging; burning the repair budget means it cannot produce valid
        # JSON at all. Counting them together would let a model that never emits
        # valid output look like one that simply needed more time.
        while steps < max_steps && attempts < max_attempts
          attempts += 1
          raw = @client.complete(system: Prompt::SYSTEM, transcript: transcript)
          step, errors = Schema.parse_step(raw, tool_names: Tools::NAMES)

          if errors.any?
            repairs += 1
            if repairs > max_repairs
              return degraded(cluster, "model repeatedly returned schema-invalid output: #{errors.first}",
                              steps, tool_calls, repairs)
            end

            transcript << { role: "assistant", content: raw.to_s }
            transcript << { role: "user", content: Prompt.repair(errors) }
            next
          end

          steps += 1

          case step["action"]
          when "classify"
            return finding(cluster, step, steps, tool_calls, repairs)
          when "use_tool"
            tool_calls += 1
            result = @tools.call(step["tool"], step["arguments"])
            transcript << { role: "assistant", content: JSON.generate(step) }
            transcript << { role: "user", content: Prompt.observation(step["tool"], result) }
          end
        end

        degraded(cluster, "reached the step budget (#{max_steps} steps) without classifying",
                 steps, tool_calls, repairs)
      rescue ProviderError, AgentError => e
        degraded(cluster, e.message, 0, 0, 0)
      end

      private

      def finding(cluster, step, steps, tool_calls, repairs)
        Finding.new(
          cluster_id: cluster.id,
          classification: step["classification"],
          confidence: step["confidence"].to_f.round(3),
          evidence: step["evidence"],
          explanation: step["explanation"].strip,
          suggested_action: step["suggested_action"].strip,
          provider: @client.name,
          model: @client.model,
          model_backed: @client.model_backed?,
          steps: steps,
          tool_calls: tool_calls,
          repairs: repairs,
          degraded: false,
          error: nil
        )
      end

      def degraded(cluster, reason, steps, tool_calls, repairs)
        Finding.degraded_for(
          cluster.id,
          provider: @client.name,
          model: @client.model,
          model_backed: @client.model_backed?,
          reason: reason,
          steps: steps,
          tool_calls: tool_calls,
          repairs: repairs
        )
      end
    end
  end
end
