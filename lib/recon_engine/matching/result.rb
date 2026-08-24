# frozen_string_literal: true

module ReconEngine
  module Matching
    # The output of the matching phase: what paired up, what did not.
    class Result < Data.define(:matches, :unmatched_ledger, :unmatched_warehouse,
                               :ledger_count, :warehouse_count)
      def strategy_counts
        matches.map(&:strategy).tally.sort.to_h
      end

      def matched_ledger_rows    = matches.sum { |m| m.ledger_rows.length }
      def matched_warehouse_rows = matches.sum { |m| m.warehouse_rows.length }

      def match_rate
        return 1.0 if ledger_count.zero?

        (matched_ledger_rows.to_f / ledger_count).round(4)
      end

      def to_report_h
        {
          ledger_rows: ledger_count,
          warehouse_rows: warehouse_count,
          matched_sets: matches.length,
          matched_ledger_rows: matched_ledger_rows,
          matched_warehouse_rows: matched_warehouse_rows,
          unmatched_ledger_rows: unmatched_ledger.length,
          unmatched_warehouse_rows: unmatched_warehouse.length,
          match_rate: match_rate,
          by_strategy: strategy_counts.transform_keys(&:to_s)
        }
      end
    end
  end
end
