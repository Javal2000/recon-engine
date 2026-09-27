# frozen_string_literal: true

RSpec.describe ReconEngine::Generator do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  it "produces byte-identical files for the same seed" do
    first  = described_class.new(seed: 7, rows: 200).write(File.join(dir, "a"))
    second = described_class.new(seed: 7, rows: 200).write(File.join(dir, "b"))

    expect(File.read(first["paths"]["ledger"])).to eq(File.read(second["paths"]["ledger"]))
    expect(File.read(first["paths"]["warehouse"])).to eq(File.read(second["paths"]["warehouse"]))
  end

  it "produces different data for a different seed" do
    a = described_class.new(seed: 1, rows: 200).write(File.join(dir, "a"))
    b = described_class.new(seed: 2, rows: 200).write(File.join(dir, "b"))

    expect(File.read(a["paths"]["ledger"])).not_to eq(File.read(b["paths"]["ledger"]))
  end

  it "writes a manifest that records every injected fault" do
    manifest = described_class.new(seed: 42, rows: 500).write(dir)

    expect(manifest["fault_counts"]).to include(
      "missing" => described_class::DEFAULT_FAULTS[:missing],
      "timing" => described_class::DEFAULT_FAULTS[:timing],
      "rounding" => described_class::DEFAULT_FAULTS[:rounding],
      "duplicated" => described_class::DEFAULT_FAULTS[:duplicated]
    )
    expect(manifest["faults"]).to all(include("kind", "txn_id"))
  end

  it "never assigns two faults to the same row" do
    manifest = described_class.new(seed: 3, rows: 500).write(dir)
    faulted  = manifest["faults"].reject { |f| f["kind"] == "orphan" }.map { |f| f["txn_id"] }

    expect(faulted.uniq.length).to eq(faulted.length)
  end

  it "writes files the engine can actually read" do
    manifest = described_class.new(seed: 5, rows: 100).write(dir)
    source   = ReconEngine::Sources::CsvSource.new(manifest["paths"]["ledger"], name: :ledger)

    expect(source.count).to eq(100)
    expect(source.first).to be_a(ReconEngine::Transaction)
  end

  it "shuffles the warehouse file so no matcher can pass by relying on row order" do
    manifest = described_class.new(seed: 11, rows: 300).write(dir)
    ledger_ids = ReconEngine::Sources::CsvSource
                 .new(manifest["paths"]["ledger"], name: :ledger).map(&:txn_id)
    warehouse_ids = ReconEngine::Sources::CsvSource
                    .new(manifest["paths"]["warehouse"], name: :warehouse).map(&:txn_id)

    expect(warehouse_ids.first(20)).not_to eq(ledger_ids.first(20))
  end

  describe "split legs" do
    it "sums exactly to the parent and keeps the legs distinct" do
      generator = described_class.new(seed: 13, rows: 50)

      [12_345, -98_765, 100, -100, 999_999].each do |cents|
        legs = generator.send(:split_amount, cents, 3)

        expect(legs.sum).to eq(cents)
        expect(legs.uniq.length).to eq(3)
        expect(legs).to all(satisfy { |leg| leg.negative? == cents.negative? })
      end
    end
  end

  it "generates only ids in the generator's own format" do
    manifest = described_class.new(seed: 42, rows: 100).write(dir)
    ids = ReconEngine::Sources::CsvSource
          .new(manifest["paths"]["warehouse"], name: :warehouse).map(&:txn_id).compact

    expect(ids).to all(match(/\A(TXN-\d{6}|WHS-ORPHAN-\d{3})\z/))
  end
end
