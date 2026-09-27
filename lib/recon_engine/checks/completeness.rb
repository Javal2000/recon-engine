# frozen_string_literal: true

module ReconEngine
  module Checks
    # Did every ledger row make it to the warehouse, and did the warehouse invent
    # any rows that were never in the ledger? Runs on what matching left over, so
    # a T+1 settlement inside the timing window never reaches this check.
    class Completeness < Base
      def call(context)
        missing = without_surplus(context.match_result.unmatched_ledger, context.ledger_profile).map do |txn|
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

        orphans = without_surplus(context.match_result.unmatched_warehouse, context.warehouse_profile).map do |txn|
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

      private

      # An extra copy of a business key that appears more than once in the same
      # source is already a Duplicates break. Reporting it here as well would
      # count the same money twice in the headline impact and scatter one cause
      # across two clusters. If no copy found a counterpart, one of them is
      # still genuinely unmatched and stays in.
      def without_surplus(unmatched, profile)
        duplicated = profile.duplicate_keys
        skipped    = Hash.new(0)

        unmatched.reject do |txn|
          copies = duplicated[txn.business_key]
          next false if copies.nil? || skipped[txn.business_key] >= copies.length - 1

          skipped[txn.business_key] += 1
          true
        end
      end
    end
  end
end
