# frozen_string_literal: true

RSpec.describe ReconEngine::Matching::Engine do
  subject(:engine) { described_class.new(config) }

  let(:config) { ReconEngine::Config.build }

  def run(ledger_rows, warehouse_rows)
    engine.call(ledger: ledger_rows, warehouse: warehouse_rows)
  end

  describe "exact key matching" do
    it "pairs rows that share a transaction id" do
      result = run(
        ledger(id: "TXN-1", amount: "10.00"),
        warehouse(id: "TXN-1", amount: "10.00")
      )

      expect(result.matches.length).to eq(1)
      expect(result.matches.first.strategy).to eq(:exact_key)
      expect(result.unmatched_ledger).to be_empty
      expect(result.unmatched_warehouse).to be_empty
    end

    it "pairs on the id even when the values disagree" do
      result = run(
        ledger(id: "TXN-1", amount: "10.00"),
        warehouse(id: "TXN-1", amount: "999.00", status: "REVERSED")
      )

      expect(result.matches.length).to eq(1)
      expect(result.matches.first.amount_delta_cents).to eq(98_900)
    end

    it "matches a duplicated id only as many times as it appears upstream" do
      result = run(
        ledger(id: "TXN-1"),
        warehouse({ id: "TXN-1" }, { id: "TXN-1" })
      )

      expect(result.matches.length).to eq(1)
      expect(result.unmatched_warehouse.length).to eq(1)
    end
  end

  describe "composite matching" do
    it "pairs on account, currency, amount and date when no id is shared" do
      result = run(
        ledger(id: "TXN-1", account: "ACC-1", amount: "25.00", date: "2026-02-01"),
        warehouse(id: nil, account: "ACC-1", amount: "25.00", date: "2026-02-01")
      )

      expect(result.matches.first.strategy).to eq(:composite)
    end

    it "absorbs a one-cent difference inside the tolerance" do
      result = run(
        ledger(id: nil, amount: "25.00"),
        warehouse(id: nil, amount: "25.01")
      )

      expect(result.matches.first.strategy).to eq(:composite)
      expect(result.matches.first.amount_delta_cents).to eq(1)
    end

    it "does not absorb a difference outside the tolerance" do
      result = run(
        ledger(id: nil, amount: "25.00"),
        warehouse(id: nil, amount: "25.02")
      )

      expect(result.matches).to be_empty
      expect(result.unmatched_ledger.length).to eq(1)
      expect(result.unmatched_warehouse.length).to eq(1)
    end

    it "matches a T+1 settlement inside the timing window" do
      result = run(
        ledger(id: nil, date: "2026-02-01"),
        warehouse(id: nil, date: "2026-02-02")
      )

      expect(result.matches.first.strategy).to eq(:composite)
      expect(result.matches.first.date_delta_days).to eq(1)
    end

    it "does not match beyond the timing window" do
      result = run(
        ledger(id: nil, date: "2026-02-01"),
        warehouse(id: nil, date: "2026-02-05")
      )

      expect(result.matches).to be_empty
    end

    it "prefers the closest candidate when several are in range" do
      result = run(
        ledger({ id: nil, amount: "25.00", row: 1 }, { id: nil, amount: "25.01", row: 2 }),
        warehouse(id: nil, amount: "25.01")
      )

      matched = result.matches.first
      expect(matched.ledger_rows.first.amount_cents).to eq(2_501)
      expect(matched.amount_delta_cents).to eq(0)
    end

    it "never matches across accounts or currencies" do
      result = run(
        ledger(id: nil, account: "ACC-1", currency: "USD"),
        warehouse(id: nil, account: "ACC-2", currency: "USD")
      )
      expect(result.matches).to be_empty

      result = run(
        ledger(id: nil, currency: "USD"),
        warehouse(id: nil, currency: "EUR")
      )
      expect(result.matches).to be_empty
    end
  end

  describe "N-to-one matching" do
    it "matches one ledger deposit against several warehouse legs" do
      result = run(
        ledger(id: nil, amount: "300.00"),
        warehouse(
          { id: nil, amount: "120.00" },
          { id: nil, amount: "100.00" },
          { id: nil, amount: "80.00" }
        )
      )

      match = result.matches.first
      expect(match.strategy).to eq(:split)
      expect(match.warehouse_rows.length).to eq(3)
      expect(match.amount_delta_cents).to eq(0)
      expect(result.unmatched_warehouse).to be_empty
    end

    it "matches several ledger lines rolled up into one warehouse row" do
      result = run(
        ledger({ id: nil, amount: "70.00" }, { id: nil, amount: "30.00" }),
        warehouse(id: nil, amount: "100.00")
      )

      match = result.matches.first
      expect(match.strategy).to eq(:split)
      expect(match.ledger_rows.length).to eq(2)
    end

    it "will not assemble a split from legs that do not sum to the parent" do
      result = run(
        ledger(id: nil, amount: "300.00"),
        warehouse({ id: nil, amount: "120.00" }, { id: nil, amount: "100.00" })
      )

      expect(result.matches).to be_empty
      expect(result.unmatched_warehouse.length).to eq(2)
    end

    it "respects the leg budget" do
      cfg    = ReconEngine::Config.build(max_split_legs: 2)
      result = described_class.new(cfg).call(
        ledger: ledger(id: nil, amount: "300.00"),
        warehouse: warehouse(
          { id: nil, amount: "100.00" },
          { id: nil, amount: "100.00" },
          { id: nil, amount: "100.00" }
        )
      )

      expect(result.matches).to be_empty
    end
  end

  describe "determinism" do
    # Matching must not depend on input order.
    it "produces the same result regardless of row order" do
      ledger_rows = ledger(
        { id: "TXN-1", amount: "10.00" },
        { id: nil, amount: "20.00" },
        { id: nil, amount: "300.00", account: "ACC-9" }
      )
      warehouse_rows = warehouse(
        { id: "TXN-1", amount: "10.00" },
        { id: nil, amount: "20.01" },
        { id: nil, amount: "100.00", account: "ACC-9" },
        { id: nil, amount: "200.00", account: "ACC-9" }
      )

      baseline = run(ledger_rows, warehouse_rows)

      5.times do |i|
        shuffled = run(
          ledger_rows.shuffle(random: Random.new(i)),
          warehouse_rows.shuffle(random: Random.new(i + 100))
        )

        expect(shuffled.strategy_counts).to eq(baseline.strategy_counts)
        expect(shuffled.matches.map(&:refs)).to eq(baseline.matches.map(&:refs))
        expect(shuffled.unmatched_ledger.map(&:ref)).to eq(baseline.unmatched_ledger.map(&:ref))
      end
    end
  end

  describe "counts" do
    it "reports totals and a match rate" do
      result = run(
        ledger({ id: "TXN-1" }, { id: "TXN-2" }),
        warehouse(id: "TXN-1")
      )

      expect(result.ledger_count).to eq(2)
      expect(result.warehouse_count).to eq(1)
      expect(result.match_rate).to eq(0.5)
    end
  end
end
