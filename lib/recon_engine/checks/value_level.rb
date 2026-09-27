# frozen_string_literal: true

module ReconEngine
  module Checks
    # For rows the matcher paired up: do they actually say the same thing?
    #
    # Matching is allowed to be generous (tolerance, timing window); this is
    # where that generosity gets recorded. A pair matched one cent apart is still
    # a penny that came from somewhere. The `band` describes the shape of a
    # difference, not its cause. Naming the cause is the agent's job.
    class ValueLevel < Base
      def call(context)
        context.match_result.matches.filter_map { |match| break_for(match) }
      end

      private

      def break_for(match)
        fields = differing_fields(match)
        return nil if fields.empty?

        Breaks::BreakRecord.build(
          type: :value_mismatch,
          partition: {
            date: match.partition_date,
            account_id: match.account_id,
            currency: match.currency
          },
          magnitude_cents: match.amount_delta_cents,
          ledger_refs: match.ledger_rows.map(&:ref),
          warehouse_refs: match.warehouse_rows.map(&:ref),
          details: {
            fields: fields,
            band: band_for(match, fields),
            strategy: match.strategy.to_s,
            ledger_amount: Money.format(match.ledger_cents),
            warehouse_amount: Money.format(match.warehouse_cents),
            amount_delta: Money.format(match.amount_delta_cents),
            date_delta_days: match.date_delta_days,
            ledger_status: match.ledger_rows.map(&:status).uniq.sort.join(","),
            warehouse_status: match.warehouse_rows.map(&:status).uniq.sort.join(",")
          }
        )
      end

      def differing_fields(match)
        fields = []
        fields << "amount"      unless match.amount_delta_cents.zero?
        fields << "posted_date" unless match.date_delta_days.zero?
        fields << "status"      unless match.statuses_agree?
        fields
      end

      def band_for(match, fields)
        if fields.include?("amount")
          if Money.within_tolerance?(match.warehouse_cents, match.ledger_cents,
                                     config.tolerance_cents)
            "sub_tolerance"
          else
            "material"
          end
        elsif fields.include?("posted_date")
          "date_shifted"
        else
          "status_only"
        end
      end
    end
  end
end
