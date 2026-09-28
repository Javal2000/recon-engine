# frozen_string_literal: true

RSpec.describe ReconEngine::History::Identity do
  # key => break, for everything the checks find in these rows.
  def keyed(ledger_rows, warehouse_rows, **schemas)
    context = context_for(ledger_rows, warehouse_rows, **schemas)
    breaks  = ReconEngine::Checks::Base.all.flat_map { |check| check.new(context.config).call(context) }
    keys    = described_class.keys_for(breaks, context)
    breaks.to_h { |record| [keys.fetch(record.id), record] }
  end

  let(:rows) do
    [{ id: "T1", amount: "10.00" }, { id: "T2", amount: "20.00", date: "2026-01-06" }, { id: "T3", amount: "30.00" }]
  end

  it "names a break by its transaction, so reordering the file changes the id but not the key" do
    before = keyed(ledger(*rows), warehouse(rows.first))
    after  = keyed(ledger(*rows.reverse), warehouse(rows.first))

    expect(after.keys).to match_array(before.keys)
    expect(after.keys).to include("missing_in_target|txn:T2", "missing_in_target|txn:T3")
    expect(after["missing_in_target|txn:T3"].id).not_to eq(before["missing_in_target|txn:T3"].id)
  end

  it "keeps a value mismatch under one key however the values disagree" do
    amount = keyed(ledger({ id: "T1", amount: "10.00" }), warehouse({ id: "T1", amount: "60.00" }))
    status = keyed(ledger({ id: "T1", status: "POSTED" }), warehouse({ id: "T1", status: "PENDING" }))

    expect(amount.keys & status.keys).to include("value_mismatch|txn:T1")
  end

  it "keys a duplicate by source and business key, and a daily total by day and currency" do
    found = keyed(ledger({ id: "T1" }), warehouse({ id: "T1" }, { id: "T1" }))

    expect(found.keys).to include("duplicate|warehouse|txn|T1", "control_total_mismatch|2026-01-05|USD",
                                  "row_count_mismatch|2026-01-05|USD")
  end

  it "keys schema drift by kind and column" do
    found = keyed(ledger({ id: "T1" }), warehouse({ id: "T1" }),
                  ledger_schema: { "amount" => "decimal" },
                  warehouse_schema: { "amount" => "decimal", "memo" => "string" })

    expect(found.keys).to include("schema_drift|column_added|memo")
  end

  # Two rows with no id and the same account, amount and date are
  # indistinguishable, so their breaks are numbered rather than merged.
  it "numbers breaks that would otherwise share a key" do
    twins   = ledger({ id: nil }, { id: nil })
    context = context_for(twins, [])
    breaks  = twins.map do |row|
      ReconEngine::Breaks::BreakRecord.build(type: :missing_in_target, partition: {}, ledger_refs: [row.ref])
    end

    keys = described_class.keys_for(breaks, context).values
    expect(keys).to contain_exactly("missing_in_target|composite:ACC-0001:USD:10000:2026-01-05",
                                    "missing_in_target|composite:ACC-0001:USD:10000:2026-01-05#2")
  end
end
