# frozen_string_literal: true

# Small builders so specs stay readable: `txn(amount: "10.00")` rather than
# Transaction.new with eight keyword arguments.
module Factories
  module_function

  def txn(source: :ledger, row: 1, id: nil, account: "ACC-0001", date: "2026-01-05",
          amount: "100.00", currency: "USD", status: "POSTED")
    ReconEngine::Transaction.new(
      source: source,
      row_number: row,
      txn_id: id,
      account_id: account,
      posted_date: date.is_a?(Date) ? date : Date.iso8601(date),
      amount_cents: amount.is_a?(Integer) ? amount : ReconEngine::Money.to_cents(amount),
      currency: currency,
      status: status
    )
  end

  def ledger(*rows)
    build_rows(:ledger, rows)
  end

  def warehouse(*rows)
    build_rows(:warehouse, rows)
  end

  def build_rows(source, rows)
    rows.each_with_index.map do |attrs, i|
      txn(**{ source: source, row: i + 1 }.merge(attrs))
    end
  end

  def config(**overrides)
    ReconEngine::Config.build(**overrides)
  end

  # Builds a Checks::Context from two row arrays using the real matcher and
  # profiler, so checks run against inputs the matcher actually produces.
  # Schemas default to empty, which is what a Profile built from rows has.
  def context_for(ledger_rows, warehouse_rows, cfg = config, ledger_schema: {}, warehouse_schema: {})
    ledger_profile    = build_profile(:ledger, ledger_rows, ledger_schema)
    warehouse_profile = build_profile(:warehouse, warehouse_rows, warehouse_schema)
    match_result      = ReconEngine::Matching::Engine.new(cfg).call(
      ledger: ledger_rows, warehouse: warehouse_rows
    )

    ReconEngine::Checks::Context.new(
      config: cfg,
      match_result: match_result,
      ledger_profile: ledger_profile,
      warehouse_profile: warehouse_profile,
      ledger_rows: ledger_rows,
      warehouse_rows: warehouse_rows
    )
  end

  def build_profile(name, rows, schema = {})
    profile = ReconEngine::Sources::Profile.new(name, schema: schema)
    rows.each { |row| profile.observe(row) }
    profile.freeze!
    profile
  end

  def write_csv(path, rows)
    headers = ReconEngine::Generator::HEADERS
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |row| csv << headers.map { |h| row[h] } }
    end
    path
  end
end
