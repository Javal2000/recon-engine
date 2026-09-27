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

      # Two separate budgets, because a step and a repair are different
      # failures. Burning the step budget means the model is investigating and
      # not converging; burning the repair budget means it cannot produce valid
      # JSON at all. Counting them together would let a model that never emits
      # valid output look like one that simply needed more time.
      def investigate(cluster)
        @usage_before = @client.usage
        @progress     = { steps: 0, tool_calls: 0, repairs: 0 }
        transcript    = [{ role: "user", content: Prompt.initial(cluster, @tools) }]

        (max_steps + max_repairs).times do
          break if @progress[:steps] >= max_steps

          outcome = take_turn(cluster, transcript)
          return outcome if outcome
        end

        degraded(cluster, "reached the step budget (#{max_steps} steps) without classifying")
      rescue ProviderError, AgentError => e
        # Report how far the investigation got before the provider failed, not
        # zeros: the calls that did succeed were real and were paid for.
        degraded(cluster, e.message)
      end

      private

      def max_steps   = @config.agent_max_steps
      def max_repairs = MAX_REPAIRS_PER_STEP * max_steps

      # One model turn. Returns a Finding once the investigation is over, or nil
      # to keep going.
      def take_turn(cluster, transcript)
        raw = @client.complete(system: Prompt::SYSTEM, transcript: transcript)
        step, errors = Schema.parse_step(raw, tool_names: Tools::NAMES)
        return repair(cluster, transcript, raw, errors) if errors.any?

        @progress[:steps] += 1
        return finding(cluster, step) if step["action"] == "classify"

        use_tool(transcript, step) if step["action"] == "use_tool"
        nil
      end

      def repair(cluster, transcript, raw, errors)
        @progress[:repairs] += 1
        if @progress[:repairs] > max_repairs
          return degraded(cluster, "model repeatedly returned schema-invalid output: #{errors.first}")
        end

        transcript << { role: "assistant", content: raw.to_s }
        transcript << { role: "user", content: Prompt.repair(errors) }
        nil
      end

      def use_tool(transcript, step)
        @progress[:tool_calls] += 1
        result = @tools.call(step["tool"], step["arguments"])
        transcript << { role: "assistant", content: JSON.generate(step) }
        transcript << { role: "user", content: Prompt.observation(step["tool"], result) }
      end

      def finding(cluster, step)
        Finding.new(
          cluster_id: cluster.id,
          classification: step["classification"],
          confidence: step["confidence"].to_f.round(3),
          evidence: step["evidence"],
          explanation: step["explanation"].strip,
          suggested_action: step["suggested_action"].strip,
          provider: @client.name, model: @client.model, model_backed: @client.model_backed?,
          **@progress, degraded: false, error: nil, usage: spent
        )
      end

      def degraded(cluster, reason)
        Finding.degraded_for(cluster.id, provider: @client.name, model: @client.model,
                                         model_backed: @client.model_backed?, reason: reason,
                                         **@progress, usage: spent)
      end

      # What this cluster cost, as opposed to the client's running total.
      def spent = @client.usage - @usage_before
    end
  end
end
