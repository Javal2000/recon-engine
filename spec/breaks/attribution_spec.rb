# frozen_string_literal: true

RSpec.describe ReconEngine::Breaks::Attribution do
  let(:cfg) { ReconEngine::Config.build }

  # Runs every real check over the rows and returns the annotated clusters.
  def clusters_for(ledger_rows, warehouse_rows)
    context = context_for(ledger_rows, warehouse_rows, cfg)
    breaks  = ReconEngine::Checks::Base.all.flat_map { |check| check.new(cfg).call(context) }
    described_class.new(breaks, context).annotate(ReconEngine::Breaks::Clusterer.call(breaks))
  end

  def attribution(clusters, type) = clusters.find { |c| c.type == type }&.attribution
  def causes(summary) = summary.components.to_h { |c| [c.cause, c.value] }

  it "explains a day's total and row count by the row that never arrived" do
    clusters = clusters_for(ledger(id: "TXN-1", amount: "50.00"), [])

    expect(causes(attribution(clusters, :control_total_mismatch))).to eq("missing_in_target" => -5_000)
    expect(causes(attribution(clusters, :row_count_mismatch))).to eq("missing_in_target" => -1)
    expect(clusters.select(&:attribution)).to all(be_explained)
  end

  it "counts only a duplicate's surplus copy, not every copy" do
    doubled  = warehouse({ id: "TXN-1", amount: "50.00" }, { id: "TXN-1", amount: "50.00" })
    clusters = clusters_for(ledger(id: "TXN-1", amount: "50.00"), doubled)

    expect(causes(attribution(clusters, :control_total_mismatch))).to eq("duplicate" => 5_000)
    expect(causes(attribution(clusters, :row_count_mismatch))).to eq("duplicate" => 1)
  end

  # The day it left and the day it arrived both have a gap, and the same late
  # row explains each of them.
  it "explains both days of a row that posted a day late" do
    clusters = clusters_for(ledger(id: nil, date: "2026-03-01", amount: "40.00"),
                            warehouse(id: nil, date: "2026-03-02", amount: "40.00"))
    totals = attribution(clusters, :control_total_mismatch)

    expect(totals).to be_explained
    expect(totals.components.map(&:cause)).to eq(["value_mismatch:date_shifted"])
  end

  # The row-count check fires on a split that reconciled perfectly; this is
  # what tells a reader it's harmless.
  it "explains the extra rows of a reconciled split without touching money" do
    legs     = warehouse({ id: nil, amount: "120.00" }, { id: nil, amount: "100.00" }, { id: nil, amount: "80.00" })
    clusters = clusters_for(ledger(id: nil, amount: "300.00"), legs)

    expect(attribution(clusters, :control_total_mismatch)).to be_nil
    expect(causes(attribution(clusters, :row_count_mismatch))).to eq("split" => 2)
  end

  describe "what the row-level breaks can't explain" do
    let(:context) { context_for([], [], cfg) }

    def control_total(date, cents)
      ReconEngine::Breaks::BreakRecord.build(type: :control_total_mismatch, magnitude_cents: cents,
                                             partition: { date: date, currency: "USD" }, details: {})
    end

    def summary_of(*breaks)
      cluster = ReconEngine::Breaks::Cluster.build(type: :control_total_mismatch, signature: { currency: "USD" },
                                                   breaks: breaks)
      described_class.new(breaks, context).annotate([cluster]).first.attribution
    end

    it "reports the whole gap as a residual when nothing accounts for it" do
      summary = summary_of(control_total("2026-01-05", 1_234))

      expect(summary).not_to be_explained
      expect(summary.residual).to eq(1_234)
    end

    # Summed over the cluster these cancel, but each day is still wrong.
    it "does not accept offsetting errors on different days as an explanation" do
      summary = summary_of(control_total("2026-01-05", 500), control_total("2026-01-06", -500))

      expect(summary.residual).to eq(0)
      expect(summary.unexplained).to eq(2)
      expect(summary).not_to be_explained
    end
  end

  it "leaves row-level clusters alone" do
    clusters = clusters_for(ledger(id: "TXN-1", amount: "50.00"), [])

    expect(clusters.select(&:row_level?).map(&:attribution)).to all(be_nil)
  end
end
