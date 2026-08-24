# frozen_string_literal: true

module ReconEngine
  module Matching
    # A decision that some ledger rows correspond to some warehouse rows,
    # usually 1:1, sometimes 1:N. It asserts identity, not agreement; whether
    # the paired rows say the same thing is checked separately.
    class MatchSet < Data.define(:strategy, :ledger_rows, :warehouse_rows)
      STRATEGIES = %i[exact_key composite split].freeze

      def self.exact(ledger, warehouse)
        new(strategy: :exact_key, ledger_rows: [ledger], warehouse_rows: [warehouse])
      end

      def self.composite(ledger, warehouse)
        new(strategy: :composite, ledger_rows: [ledger], warehouse_rows: [warehouse])
      end

      def self.split(ledger_rows, warehouse_rows)
        new(strategy: :split, ledger_rows: Array(ledger_rows), warehouse_rows: Array(warehouse_rows))
      end

      def ledger_cents    = ledger_rows.sum(&:amount_cents)
      def warehouse_cents = warehouse_rows.sum(&:amount_cents)
      def amount_delta_cents = warehouse_cents - ledger_cents

      def one_to_one? = ledger_rows.length == 1 && warehouse_rows.length == 1

      # Largest posted-date gap across the set, signed: positive means the
      # warehouse side is later, which is what a T+1 settlement looks like.
      def date_delta_days
        (warehouse_rows.map(&:posted_date).max - ledger_rows.map(&:posted_date).min).to_i
      end

      def statuses_agree?
        ledger_rows.map(&:status).uniq == warehouse_rows.map(&:status).uniq
      end

      def account_id = ledger_rows.first.account_id
      def currency   = ledger_rows.first.currency
      def partition_date = ledger_rows.map(&:posted_date).min

      def refs = (ledger_rows + warehouse_rows).map(&:ref)

      # Deterministic ordering handle, so reports never depend on hash order.
      def sort_key = ledger_rows.first.sort_key

      def to_report_h
        {
          strategy: strategy.to_s,
          ledger: ledger_rows.map(&:to_report_h),
          warehouse: warehouse_rows.map(&:to_report_h)
        }
      end
    end
  end
end
