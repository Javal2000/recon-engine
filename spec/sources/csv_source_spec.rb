# frozen_string_literal: true

RSpec.describe ReconEngine::Sources::CsvSource do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  def source_for(rows, name: :ledger)
    path = write_csv(File.join(@dir, "#{name}.csv"), rows)
    described_class.new(path, name: name)
  end

  def row(overrides = {})
    {
      "txn_id" => "TXN-1", "account_id" => "ACC-1", "posted_date" => "2026-01-05",
      "amount" => "100.00", "currency" => "usd", "status" => "posted"
    }.merge(overrides)
  end

  it "parses rows into normalized transactions" do
    txn = source_for([row]).first

    expect(txn.txn_id).to eq("TXN-1")
    expect(txn.amount_cents).to eq(10_000)
    expect(txn.posted_date).to eq(Date.new(2026, 1, 5))
    expect(txn.currency).to eq("USD")
    expect(txn.status).to eq("POSTED")
    expect(txn.row_number).to eq(1)
    expect(txn.source).to eq(:ledger)
  end

  it "treats a blank transaction id as absent, not as an id" do
    txn = source_for([row("txn_id" => "  ")]).first

    expect(txn.keyed?).to be(false)
    expect(txn.txn_id).to be_nil
    expect(txn.business_key.first).to eq("composite")
  end

  it "is Enumerable, so it composes with the rest of Ruby" do
    source = source_for([row, row("txn_id" => "TXN-2", "amount" => "5.00")])

    expect(source.count).to eq(2)
    expect(source.map(&:amount_cents).sum).to eq(10_500)
    expect(source.lazy.first(1).length).to eq(1)
  end

  it "streams, so iterating twice does not accumulate state" do
    source = source_for([row, row("txn_id" => "TXN-2")])

    expect(source.map(&:row_number)).to eq([1, 2])
    expect(source.map(&:row_number)).to eq([1, 2])
  end

  describe "input validation" do
    it "names the missing column" do
      path = File.join(@dir, "bad.csv")
      CSV.open(path, "w") { |csv| csv << %w[txn_id account_id] << %w[TXN-1 ACC-1] }

      expect { described_class.new(path, name: :ledger).to_a }
        .to raise_error(ReconEngine::InputError, /missing required column\(s\): posted_date/)
    end

    it "names the row and column for a bad date" do
      expect { source_for([row("posted_date" => "05/01/2026")]).to_a }
        .to raise_error(ReconEngine::InputError, /row 1: posted_date/)
    end

    it "names the row for a bad amount" do
      expect { source_for([row("amount" => "one hundred")]).to_a }
        .to raise_error(ReconEngine::InputError, /row 1/)
    end

    it "refuses a file that does not exist" do
      expect { described_class.new(File.join(@dir, "nope.csv"), name: :ledger) }
        .to raise_error(ReconEngine::InputError, /does not exist/)
    end
  end

  it "hashes its own contents so a run can be pinned to exact bytes" do
    a = source_for([row], name: :ledger)
    b = source_for([row], name: :warehouse)
    c = source_for([row("amount" => "100.01")], name: :other)

    expect(a.digest).to eq(b.digest)
    expect(a.digest).not_to eq(c.digest)
  end

  it "infers a schema for the agent's get_schema tool" do
    schema = source_for([row]).schema

    expect(schema["posted_date"]).to eq("date")
    expect(schema["amount"]).to eq("decimal")
    expect(schema["account_id"]).to eq("string")
  end

  describe "type inference across a sample" do
    # Each of these would be a false positive if types came from the first row.
    it "widens integer to decimal when the column holds both" do
      schema = source_for([row("amount" => "100"), row("amount" => "100.50")]).schema

      expect(schema["amount"]).to eq("decimal")
    end

    it "does not let the first row decide the column's type" do
      schema = source_for([row("txn_id" => "1"), row("txn_id" => "TXN-2")]).schema

      expect(schema["txn_id"]).to eq("string")
    end

    it "reports a wholly blank column as unknown rather than guessing" do
      schema = source_for([row("txn_id" => ""), row("txn_id" => "  ")]).schema

      expect(schema["txn_id"]).to eq("unknown")
    end
  end
end
