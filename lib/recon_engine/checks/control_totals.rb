# frozen_string_literal: true

module ReconEngine
  module Checks
    # Do the sums tie, per (posted date, currency)?
    #
    # Catches what row matching can't: a pipeline that truncates the third
    # decimal place leaves every row matched and every daily total wrong. These
    # are aggregate breaks, kept out of the headline impact so a missing row
    # isn't counted twice.
    class ControlTotals < Base
      def call(context)
        ledger    = context.ledger_profile
        warehouse = context.warehouse_profile

        partitions = (ledger.partitions | warehouse.partitions).sort_by { |date, currency| [date, currency] }

        partitions.flat_map do |partition|
          date, currency = partition
          amount_break = amount_break_for(partition, date, currency, ledger, warehouse)
          count_break  = count_break_for(partition, date, currency, ledger, warehouse)
          [amount_break, count_break].compact
        end
      end

      private

      def amount_break_for(partition, date, currency, ledger, warehouse)
        ledger_cents    = ledger.totals_by_partition.fetch(partition, 0)
        warehouse_cents = warehouse.totals_by_partition.fetch(partition, 0)
        delta           = warehouse_cents - ledger_cents
        return nil if delta.zero?

        Breaks::BreakRecord.build(
          type: :control_total_mismatch,
          partition: { date: date, account_id: nil, currency: currency },
          magnitude_cents: delta,
          details: {
            ledger_total: Money.format(ledger_cents),
            warehouse_total: Money.format(warehouse_cents),
            delta: Money.format(delta)
          }
        )
      end

      def count_break_for(partition, date, currency, ledger, warehouse)
        ledger_rows    = ledger.rows_by_partition.fetch(partition, 0)
        warehouse_rows = warehouse.rows_by_partition.fetch(partition, 0)
        return nil if ledger_rows == warehouse_rows

        Breaks::BreakRecord.build(
          type: :row_count_mismatch,
          partition: { date: date, account_id: nil, currency: currency },
          magnitude_cents: 0,
          details: {
            ledger_rows: ledger_rows,
            warehouse_rows: warehouse_rows,
            delta: warehouse_rows - ledger_rows
          }
        )
      end
    end
  end
end
