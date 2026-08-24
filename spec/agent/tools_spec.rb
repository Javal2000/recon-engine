# frozen_string_literal: true

RSpec.describe ReconEngine::Agent::Tools do
  let(:cfg) { ReconEngine::Config.build }
  let(:ledger_rows) do
    ledger(
      { id: "TXN-1", account: "ACC-1", amount: "100.00", date: "2026-01-05" },
      { id: "TXN-2", account: "ACC-1", amount: "250.00", date: "2026-01-06" },
      { id: "TXN-3", account: "ACC-2", amount: "-40.00", date: "2026-01-05" }
    )
  end
  let(:warehouse_rows) do
    warehouse({ id: "TXN-2", account: "ACC-1", amount: "250.00", date: "2026-01-06" })
  end
  let(:context) { context_for(ledger_rows, warehouse_rows, cfg) }
  let(:breaks)  { ReconEngine::Checks::Completeness.new(cfg).call(context) }
  let(:tools)   { described_class.new(context: context, breaks: breaks) }

  describe "#fetch_rows" do
    it "filters by source and account" do
      result = tools.call("fetch_rows", { "source" => "ledger", "account_id" => "ACC-1" })

      expect(result["matched_rows"]).to eq(2)
      expect(result["rows"].map { |r| r["txn_id"] }).to contain_exactly("TXN-1", "TXN-2")
    end

    it "caps the number of rows it will return" do
      result = tools.call("fetch_rows", { "source" => "ledger", "limit" => 999 })

      expect(result["returned"]).to be <= described_class::MAX_ROWS
    end

    it "returns an error rather than raising on a bad source" do
      result = tools.call("fetch_rows", { "source" => "production_database" })

      expect(result["error"]).to include("ledger")
    end
  end

  describe "#check_adjacent_periods" do
    # The row isn't gone, it's on the next day.
    it "finds the counterpart of a T+1 settlement in the adjacent day" do
      ctx = context_for(
        ledger(id: "TXN-1", account: "ACC-1", amount: "100.00", date: "2026-01-05"),
        warehouse(id: nil, account: "ACC-1", amount: "100.00", date: "2026-01-06"),
        ReconEngine::Config.build(timing_window_days: 1)
      )

      result = described_class.new(context: ctx, breaks: []).call(
        "check_adjacent_periods",
        { "account_id" => "ACC-1", "date" => "2026-01-05", "amount" => "100.00", "currency" => "USD" }
      )

      expect(result["candidate_matches_in_adjacent_period"]).to eq(1)
    end

    it "reports no adjacent counterpart when the row is really gone" do
      ctx = context_for(
        ledger(id: "TXN-1", account: "ACC-1", amount: "100.00", date: "2026-01-05"),
        [],
        ReconEngine::Config.build(timing_window_days: 1)
      )

      result = described_class.new(context: ctx, breaks: []).call(
        "check_adjacent_periods",
        { "account_id" => "ACC-1", "date" => "2026-01-05", "amount" => "100.00", "currency" => "USD" }
      )

      expect(result["candidate_matches_in_adjacent_period"]).to eq(0)
    end

    it "counts rows on each day of the window" do
      result = tools.call("check_adjacent_periods", {
                            "account_id" => "ACC-1", "date" => "2026-01-05",
                            "amount" => "100.00", "currency" => "USD"
                          })

      expect(result["per_day"].map { |d| d["date"] })
        .to eq(%w[2026-01-04 2026-01-05 2026-01-06])
      expect(result["per_day"].find { |d| d["date"] == "2026-01-05" }["ledger_rows"]).to eq(1)
    end

    it "returns an error for an unparseable date instead of blowing up the run" do
      result = tools.call("check_adjacent_periods", {
                            "account_id" => "ACC-1", "date" => "last tuesday", "amount" => "1.00"
                          })

      expect(result["error"]).to include("check_adjacent_periods failed")
    end
  end

  describe "#get_schema" do
    it "describes the columns of a source" do
      result = tools.call("get_schema", { "source" => "warehouse" })

      expect(result["row_count"]).to eq(1)
      expect(result["source"]).to eq("warehouse")
    end
  end

  describe "#summarize_cluster" do
    it "aggregates the breaks it is given" do
      result = tools.call("summarize_cluster", { "break_ids" => breaks.map(&:id) })

      expect(result["resolved"]).to eq(breaks.length)
      expect(result["types"]).to include("missing_in_target")
    end

    it "reports ids it does not recognise" do
      result = tools.call("summarize_cluster", { "break_ids" => ["brk_nope"] })

      expect(result["error"]).to include("brk_nope")
    end
  end

  describe "guardrails" do
    it "refuses an unknown tool by name, and says what is available" do
      result = tools.call("delete_everything", {})

      expect(result["error"]).to include("unknown tool")
      described_class::NAMES.each { |name| expect(result["error"]).to include(name) }
    end

    # No tool may decide whether records match, and none may write anything.
    it "exposes only read-only, non-adjudicating tools" do
      expect(described_class::NAMES).to contain_exactly(
        "fetch_rows", "check_adjacent_periods", "get_schema", "summarize_cluster"
      )
    end

    it "counts every call it makes" do
      3.times { tools.call("get_schema", { "source" => "ledger" }) }

      expect(tools.calls).to eq(3)
    end
  end
end
