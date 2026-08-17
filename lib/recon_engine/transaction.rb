# frozen_string_literal: true

module ReconEngine
  # One row of transaction data, normalized.
  class Transaction < Data.define(
    :source,        # :ledger or :warehouse. Where this row came from
    :row_number,    # 1-based line number in the source file, for traceability
    :txn_id,        # shared transaction id; may be nil or empty in the warehouse
    :account_id,
    :posted_date,   # Date
    :amount_cents,  # Integer, see Money
    :currency,
    :status
  )
    # True when this row carries a transaction id both systems share.
    def keyed?
      !txn_id.nil? && !txn_id.empty?
    end

    # The fallback identity when no shared id exists. Composite matching probes
    # around this tuple with an amount tolerance and a date window.
    def composite_key
      [account_id, currency, amount_cents, posted_date]
    end

    # The identity used for duplicate detection *within* one source. Deliberately
    # excludes row_number so two otherwise-identical rows collide.
    def business_key
      if keyed?
        ["txn", txn_id]
      else
        ["composite", account_id, currency, amount_cents, posted_date.iso8601]
      end
    end

    # Stable, human-readable pointer used in break records and agent evidence.
    def ref
      "#{source}:#{row_number}"
    end

    def to_report_h
      {
        ref: ref,
        source: source.to_s,
        row_number: row_number,
        txn_id: txn_id,
        account_id: account_id,
        posted_date: posted_date.iso8601,
        amount: Money.format(amount_cents),
        currency: currency,
        status: status
      }
    end

    # Deterministic sort key, so nothing that reaches a report depends on
    # input order.
    def sort_key
      [posted_date, account_id, amount_cents, txn_id.to_s, row_number]
    end
  end
end
