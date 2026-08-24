# frozen_string_literal: true

module ReconEngine
  module Checks
    # Does the same business key appear more than once within a single source?
    #
    # Matching pairs the first occurrence and leaves the rest as orphans, which
    # describes the symptom. This names the cause: one replayed delivery rather
    # than a pile of unexplained orphans.
    class Duplicates < Base
      def call(context)
        %i[ledger warehouse].flat_map do |source|
          profile = context.profile_for(source)
          index   = context.rows_for(source)

          profile.duplicate_keys.sort_by { |_key, rows| rows.first }.map do |key, row_numbers|
            build_break(source, key, row_numbers, index)
          end
        end
      end

      private

      def build_break(source, key, row_numbers, index)
        rows      = row_numbers.map { |n| index.fetch(n) }
        first     = rows.first
        # Every occurrence after the first is surplus money in the source.
        magnitude = first.amount_cents * (rows.length - 1)
        refs      = rows.map(&:ref)

        Breaks::BreakRecord.build(
          type: :duplicate,
          partition: { date: first.posted_date, account_id: first.account_id, currency: first.currency },
          magnitude_cents: magnitude,
          ledger_refs: source == :ledger ? refs : [],
          warehouse_refs: source == :warehouse ? refs : [],
          details: {
            source: source.to_s,
            business_key: key.join("|"),
            occurrences: rows.length,
            row_numbers: row_numbers,
            unit_amount: Money.format(first.amount_cents)
          }
        )
      end
    end
  end
end
