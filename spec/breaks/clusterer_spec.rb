# frozen_string_literal: true

RSpec.describe ReconEngine::Breaks::Clusterer do
  let(:cfg) { ReconEngine::Config.build }

  def missing_break(date:, currency: "USD", amount: 1_000, account: "ACC-1")
    ReconEngine::Breaks::BreakRecord.build(
      type: :missing_in_target,
      partition: { date: Date.iso8601(date), account_id: account, currency: currency },
      magnitude_cents: amount,
      ledger_refs: ["ledger:#{rand(1_000_000)}"]
    )
  end

  it "collapses many breaks from one upstream cause into one finding" do
    breaks = Array.new(500) { missing_break(date: "2026-01-05") }

    clusters = described_class.call(breaks)

    expect(clusters.length).to eq(1)
    expect(clusters.first.count).to eq(500)
    expect(clusters.first.magnitude_cents).to eq(500_000)
  end

  it "keeps different problems apart" do
    breaks = [
      missing_break(date: "2026-01-05"),
      missing_break(date: "2026-01-06"),
      missing_break(date: "2026-01-05", currency: "EUR")
    ]

    expect(described_class.call(breaks).length).to eq(3)
  end

  it "keeps only a handful of samples no matter how large the cluster" do
    clusters = described_class.call(Array.new(500) { missing_break(date: "2026-01-05") })

    expect(clusters.first.samples.length).to eq(ReconEngine::Breaks::Cluster::MAX_SAMPLES)
    expect(clusters.first.break_ids.length).to eq(500)
  end

  describe "ordering" do
    let(:row_level) { missing_break(date: "2026-01-05", amount: 100) }
    let(:aggregate) do
      ReconEngine::Breaks::BreakRecord.build(
        type: :control_total_mismatch,
        partition: { date: Date.iso8601("2026-01-05"), account_id: nil, currency: "USD" },
        magnitude_cents: 9_999_999
      )
    end

    # Causes before consequences: a control total that doesn't tie is caused by
    # rows that are wrong, however large its number.
    it "puts row-level clusters ahead of aggregate ones even when smaller" do
      clusters = described_class.call([aggregate, row_level])

      expect(clusters.first.type).to eq(:missing_in_target)
      expect(clusters.last.type).to eq(:control_total_mismatch)
    end

    it "orders by magnitude within a level" do
      small = missing_break(date: "2026-01-05", amount: 100)
      big   = missing_break(date: "2026-01-06", amount: 900_000)

      expect(described_class.call([small, big]).first.magnitude_cents).to eq(900_000)
    end

    it "ranks a large zero-dollar cluster above a small zero-dollar one" do
      many = Array.new(50) { missing_break(date: "2026-01-05", amount: 0) }
      few  = [missing_break(date: "2026-01-06", amount: 0)]

      expect(described_class.call(many + few).first.count).to eq(50)
    end

    it "is a total order, so the same breaks always cluster in the same sequence" do
      breaks = [
        missing_break(date: "2026-01-05", amount: 500),
        missing_break(date: "2026-01-06", amount: 500),
        missing_break(date: "2026-01-07", amount: 500)
      ]

      baseline = described_class.call(breaks).map(&:id)
      5.times { expect(described_class.call(breaks.shuffle).map(&:id)).to eq(baseline) }
    end
  end

  it "gives a cluster a stable id derived from its type and signature" do
    first  = described_class.call([missing_break(date: "2026-01-05")]).first
    second = described_class.call([missing_break(date: "2026-01-05")]).first

    expect(first.id).to eq(second.id)
    expect(first.id).to start_with("cls_")
  end
end
