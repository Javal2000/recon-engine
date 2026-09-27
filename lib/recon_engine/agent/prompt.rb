# frozen_string_literal: true

module ReconEngine
  module Agent
    # All prompt text lives here, so the contract with the model can be read in
    # one place. The system prompt says explicitly that the model must not
    # decide whether two amounts are equal. The cluster goes in as JSON inside
    # <cluster> tags, which the offline provider parses too.
    module Prompt
      SYSTEM = <<~TEXT.freeze
        You are a reconciliation analyst. A deterministic engine has already
        compared two systems and found breaks. It has grouped similar breaks into
        clusters. Your job is to explain ONE cluster: why it happened.

        Rules:
        - The deterministic engine decides what matches and what does not. You do
          not. Never re-derive whether two amounts are equal, and never contradict
          a break that was reported to you. Explain it.
        - Investigate before you conclude. Call at least one tool.
        - Ground every claim in a tool result. If the tools do not support a
          conclusion, classify as UNKNOWN with low confidence. An honest UNKNOWN
          is more useful than a confident guess, because a human will act on it.
        - Reply with a single JSON object and nothing else. No prose, no markdown
          fences, no commentary before or after.

        Each reply is exactly one of these two shapes.

        To use a tool:
        {"action":"use_tool","tool":"<tool name>","arguments":{ ... }}

        To finish:
        {"action":"classify",
         "classification":"<one of: #{Schema::CLASSIFICATIONS.join(" | ")}>",
         "confidence":<number between 0 and 1>,
         "evidence":["<specific fact from a tool result>", "..."],
         "explanation":"<two or three sentences: what happened and why>",
         "suggested_action":"<what an engineer should do about it>"}

        Classification meanings:
        - TIMING_DIFFERENCE: the record exists on both sides but on different
          days, e.g. T+1 settlement. Not a data-loss problem.
        - ROUNDING: values differ by a precision artefact, not a value change.
        - DUPLICATE_IN_TARGET: the downstream system holds the same record more
          than once.
        - MISSING_IN_TARGET: a ledger record that never arrived in the warehouse.
          Only for rows present upstream and absent downstream.
        - SCHEMA_DRIFT: a column changed name, type or presence between systems.
        - GENUINE_DISCREPANCY: a real disagreement that needs a human, including
          a warehouse row with no ledger record behind it.
        - UNKNOWN: the evidence does not support any of the above.
      TEXT

      module_function

      def initial(cluster, tools)
        <<~TEXT
          Investigate this break cluster.

          <cluster>
          #{JSON.pretty_generate(cluster.to_report_h)}
          </cluster>

          Tools available to you:
          #{tools.descriptor}

          Reply with one JSON object: either a tool call or a classification.
        TEXT
      end

      def observation(tool_name, result)
        <<~TEXT
          Result of #{tool_name}:

          <observation>
          #{JSON.pretty_generate(result)}
          </observation>

          Reply with one JSON object: another tool call, or your classification.
        TEXT
      end

      # Fed back verbatim after a schema violation. Repeating the exact errors
      # rather than a generic "invalid, try again" is what makes the single retry
      # usually sufficient.
      def repair(errors)
        <<~TEXT
          Your previous reply did not satisfy the required schema:

          #{errors.map { |e| "- #{e}" }.join("\n")}

          Reply again with a single valid JSON object and nothing else.
        TEXT
      end
    end
  end
end
