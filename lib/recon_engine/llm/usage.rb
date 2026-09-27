# frozen_string_literal: true

module ReconEngine
  module LLM
    # What model calls cost: tokens and time.
    #
    # Thinking tokens are kept apart from output tokens because reasoning models
    # bill for them without ever returning them, and they can outnumber the
    # visible answer many times over. Time spent waiting out a rate limit is kept
    # apart from time spent in the model, so neither figure hides the other.
    class Usage < Data.define(:calls, :input_tokens, :output_tokens, :thinking_tokens, :latency_ms, :wait_ms)
      def self.zero
        new(calls: 0, input_tokens: 0, output_tokens: 0, thinking_tokens: 0, latency_ms: 0, wait_ms: 0)
      end

      def +(other) = combine(other) { |a, b| a + b }
      def -(other) = combine(other) { |a, b| a - b }

      def total_tokens = input_tokens + output_tokens + thinking_tokens

      def to_report_h = to_h.merge(total_tokens: total_tokens)

      private

      def combine(other)
        self.class.new(**to_h.merge(other.to_h) { |_field, mine, theirs| yield(mine, theirs) })
      end
    end
  end
end
