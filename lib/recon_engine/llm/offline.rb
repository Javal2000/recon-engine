# frozen_string_literal: true

module ReconEngine
  module LLM
    # A scripted stand-in that speaks the agent protocol without calling a model.
    # It is a small rule table, not an AI. It lets the demo run with no
    # credentials, lets CI exercise the real tool loop and retry path for free,
    # and gives the golden-set eval a baseline to compare real models against.
    # Reports mark its findings as not model-backed.
    class Offline < Client
      # Not guessed. A control-total delta comes from some mix of row-level
      # breaks in the same partition, and attributing it means cross-referencing
      # them, which a rule table can't do and a model can.
      CONTROL_TOTAL_VERDICT = [
        "UNKNOWN",
        "Daily totals do not tie for this currency, but a control-total delta is a consequence of row-level " \
        "breaks rather than a cause. Attributing it requires cross-referencing the row-level clusters in the " \
        "same partitions, which the scripted provider does not do."
      ].freeze

      def self.default_model = "scripted-v1"

      def model_backed? = false

      def complete(system:, transcript:) # rubocop:disable Lint/UnusedMethodArgument
        cluster      = extract_tagged(transcript, "cluster") || {}
        observations = observations_in(transcript)

        case observations.length
        when 0 then summarize_first(cluster)
        when 1 then second_probe(cluster)
        else classify(cluster, observations)
        end
      end

      private

      # --- step 1 ------------------------------------------------------------

      def summarize_first(cluster)
        tool_call("summarize_cluster", { "break_ids" => Array(cluster["break_ids"]).first(5) })
      end

      # --- step 2 ------------------------------------------------------------

      def second_probe(cluster)
        sample = Array(cluster["sample_breaks"]).first || {}
        partition = sample["partition"] || {}

        case cluster["type"]
        when "missing_in_target", "orphan_in_target"
          tool_call("check_adjacent_periods", {
                      "account_id" => partition["account_id"],
                      "date" => partition["date"],
                      "amount" => sample.dig("details", "amount"),
                      "currency" => partition["currency"]
                    })
        else
          tool_call("fetch_rows", {
                      "source" => cluster["type"] == "duplicate" ? sample.dig("details", "source") : "warehouse",
                      "account_id" => partition["account_id"],
                      "date" => partition["date"],
                      "limit" => 5
                    })
        end
      end

      # --- step 3 ------------------------------------------------------------

      def classify(cluster, observations)
        classification, reason = decide(cluster, observations)
        JSON.generate({
                        "action" => "classify",
                        "classification" => classification,
                        "confidence" => confidence_for(classification),
                        "evidence" => evidence_for(cluster, observations),
                        "explanation" => reason,
                        "suggested_action" => suggestion_for(classification)
                      })
      end

      # The rule table, kept as a plain `case` so it's obvious how little of the
      # offline demo is actual inference.
      def decide(cluster, observations)
        details = (Array(cluster["sample_breaks"]).first || {})["details"] || {}

        case cluster["type"]
        when "missing_in_target"      then missing_verdict(adjacent_matches(observations))
        when "orphan_in_target"       then orphan_verdict(adjacent_matches(observations))
        when "duplicate"              then duplicate_verdict(details)
        when "value_mismatch"         then value_mismatch_verdict(details)
        when "control_total_mismatch" then CONTROL_TOTAL_VERDICT
        when "row_count_mismatch"     then row_count_verdict(details)
        # The check has already established what changed, so the break's shape
        # is the answer and a rule table does as well as a model here.
        when "schema_drift"           then ["SCHEMA_DRIFT", schema_drift_reason(details)]
        else ["UNKNOWN", "No rule covers break type #{cluster["type"]}."]
        end
      end

      def adjacent_matches(observations)
        adjacency = observations.find { |o| o.key?("candidate_matches_in_adjacent_period") }
        adjacency ? adjacency["candidate_matches_in_adjacent_period"].to_i : 0
      end

      def missing_verdict(adjacent)
        if adjacent.positive?
          ["TIMING_DIFFERENCE",
           "A row with the same account, currency and amount is present in the warehouse in an adjacent " \
           "period, which is the signature of a settlement lag rather than a dropped record."]
        else
          ["MISSING_IN_TARGET",
           "No corresponding warehouse row exists on the break date or in the adjacent periods, so the " \
           "record did not arrive at all."]
        end
      end

      def orphan_verdict(adjacent)
        if adjacent.positive?
          ["TIMING_DIFFERENCE",
           "The ledger carries an equivalent row in an adjacent period, so the warehouse row is early or " \
           "late rather than fabricated."]
        else
          ["GENUINE_DISCREPANCY",
           "The warehouse contains a row with no ledger counterpart in the surrounding window."]
        end
      end

      def duplicate_verdict(details)
        ["DUPLICATE_IN_TARGET",
         "The same business key appears #{details["occurrences"]} times in #{details["source"]}, which is " \
         "at-least-once delivery replaying a record rather than genuine repeated activity."]
      end

      def row_count_verdict(details)
        if details["delta"].to_i.negative?
          ["MISSING_IN_TARGET", "The warehouse holds fewer rows than the ledger for this partition."]
        else
          ["DUPLICATE_IN_TARGET", "The warehouse holds more rows than the ledger for this partition."]
        end
      end

      def schema_drift_reason(details)
        case details["kind"]
        when "column_missing"
          "The ledger column #{details["column"].inspect} has no warehouse counterpart, so whatever it carried " \
          "is not being loaded."
        when "column_added"
          "The warehouse carries a column #{details["column"].inspect} the ledger does not, which is a " \
          "downstream transformation rather than source data."
        else
          "Column #{details["column"].inspect} is #{details["ledger_type"]} upstream and " \
          "#{details["warehouse_type"]} downstream; a type narrowing in transit silently loses precision."
        end
      end

      def value_mismatch_verdict(details)
        case details["band"]
        when "sub_tolerance"
          ["ROUNDING",
           "Matched rows differ by #{details["amount_delta"]}, inside the configured tolerance: a precision " \
           "loss in transit, not a value change."]
        when "date_shifted"
          ["TIMING_DIFFERENCE",
           "Matched rows agree on amount but the warehouse posted date is #{details["date_delta_days"]} day(s) " \
           "later, consistent with T+1 settlement."]
        else
          ["GENUINE_DISCREPANCY",
           "Matched rows disagree on #{Array(details["fields"]).join(" and ")} by more than tolerance."]
        end
      end

      def confidence_for(classification)
        # Scripted rules are stated at fixed confidence, and never at 1.0: a
        # classification that cannot be wrong does not need a confidence field.
        classification == "UNKNOWN" ? 0.2 : 0.75
      end

      def evidence_for(cluster, observations)
        [
          "cluster #{cluster["id"]} contains #{cluster["break_count"]} break(s) worth #{cluster["magnitude"]}",
          "tool observations: #{observations.length}"
        ]
      end

      def suggestion_for(classification)
        {
          "TIMING_DIFFERENCE" => "Widen the settlement window for this feed or re-run after the next load.",
          "ROUNDING" => "Compare the decimal precision of the source column with the warehouse column type.",
          "DUPLICATE_IN_TARGET" => "Add an idempotency key on the load job and de-duplicate the affected partition.",
          "MISSING_IN_TARGET" => "Replay the extract for the affected partition and confirm the row count ties.",
          "SCHEMA_DRIFT" => "Reconcile the two column definitions before trusting any run over this feed.",
          "GENUINE_DISCREPANCY" => "Escalate to the data owner with the sample rows attached.",
          "UNKNOWN" => "Investigate manually: no rule matched."
        }.fetch(classification, "Investigate manually.")
      end

      # --- transcript parsing ------------------------------------------------

      def tool_call(name, arguments)
        JSON.generate({ "action" => "use_tool", "tool" => name, "arguments" => arguments })
      end

      def observations_in(transcript)
        transcript.flat_map { |turn| extract_all_tagged(turn[:content], "observation") }
      end

      def extract_tagged(transcript, tag)
        transcript.each do |turn|
          found = extract_all_tagged(turn[:content], tag).first
          return found if found
        end
        nil
      end

      def extract_all_tagged(content, tag)
        content.to_s.scan(%r{<#{tag}>\s*(.*?)\s*</#{tag}>}m).filter_map do |(body)|
          JSON.parse(body)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
