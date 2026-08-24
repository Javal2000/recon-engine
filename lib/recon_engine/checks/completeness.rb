# frozen_string_literal: true

module ReconEngine
  module Checks
    # Did every ledger row make it to the warehouse, and did the warehouse invent
    # any rows that were never in the ledger? Runs on what matching left over, so
    # a T+1 settlement inside the timing window never reaches this check.
    class Completeness < Base
      def call(context)
        missing = context.match_result.unmatched_ledger.map do |txn|
          Breaks::BreakRecord.build(
            type: :missing_in_target,
            partition: { date: txn.posted_date, account_id: txn.account_id, currency: txn.currency },
            magnitude_cents: txn.amount_cents,
            ledger_refs: [txn.ref],
            details: {
              txn_id: txn.txn_id,
              amount: Money.format(txn.amount_cents),
              status: txn.status
            }
          )
        end

        orphans = context.match_result.unmatched_warehouse.map do |txn|
          Breaks::BreakRecord.build(
            type: :orphan_in_target,
            partition: { date: txn.posted_date, account_id: txn.account_id, currency: txn.currency },
            magnitude_cents: txn.amount_cents,
            warehouse_refs: [txn.ref],
            details: {
              txn_id: txn.txn_id,
              amount: Money.format(txn.amount_cents),
              status: txn.status
            }
          )
        end

        missing + orphans
      end
    end
  end
end
