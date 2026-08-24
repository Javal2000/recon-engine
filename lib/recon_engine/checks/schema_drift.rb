# frozen_string_literal: true

module ReconEngine
  module Checks
    # Compares the two sources' schemas rather than their values, so it is the
    # only check that can fire on data where every row reconciles perfectly. A
    # column that changed type gets flagged before any bad values come through.
    #
    # Detects a column missing downstream, a column added downstream, and a
    # column whose type changed. Drift between this run and a previous one would
    # need persisted run history, which v1 does not keep.
    class SchemaDrift < Base
      def call(context)
        ledger    = context.ledger_profile.schema
        warehouse = context.warehouse_profile.schema
        # Empty means "not inferred", not "no columns"; a Profile built from
        # rows rather than a file has one.
        return [] if ledger.empty? || warehouse.empty?

        missing_columns(ledger, warehouse) +
          added_columns(ledger, warehouse) +
          retyped_columns(ledger, warehouse)
      end

      private

      def missing_columns(ledger, warehouse)
        (ledger.keys - warehouse.keys).sort.map do |column|
          drift(
            kind: "column_missing",
            column: column,
            ledger_type: ledger[column],
            warehouse_type: nil,
            summary: "column #{column.inspect} is present in the ledger and absent from the warehouse"
          )
        end
      end

      def added_columns(ledger, warehouse)
        (warehouse.keys - ledger.keys).sort.map do |column|
          drift(
            kind: "column_added",
            column: column,
            ledger_type: nil,
            warehouse_type: warehouse[column],
            summary: "column #{column.inspect} is present in the warehouse and absent from the ledger"
          )
        end
      end

      # "unknown" means the sample was entirely blank, so there is no type to
      # compare and no evidence of drift.
      def retyped_columns(ledger, warehouse)
        (ledger.keys & warehouse.keys).sort.filter_map do |column|
          left  = ledger[column]
          right = warehouse[column]
          next if left == right || left == "unknown" || right == "unknown"

          drift(
            kind: "type_changed",
            column: column,
            ledger_type: left,
            warehouse_type: right,
            summary: "column #{column.inspect} is #{left} in the ledger and #{right} in the warehouse"
          )
        end
      end

      def drift(kind:, column:, ledger_type:, warehouse_type:, summary:)
        Breaks::BreakRecord.build(
          type: :schema_drift,
          # Schema is a property of the whole file, so there is no date, account
          # or currency to scope this to.
          partition: {},
          magnitude_cents: 0,
          details: {
            kind: kind,
            column: column,
            ledger_type: ledger_type,
            warehouse_type: warehouse_type,
            summary: summary
          }
        )
      end
    end
  end
end
