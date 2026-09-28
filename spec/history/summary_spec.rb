# frozen_string_literal: true

RSpec.describe ReconEngine::History::Summary do
  let(:run_two) { ReconEngine::History::RunInfo.new(2, "2026-01-16T09:00:00Z", "b" * 64, "cfg", 3, 0) }
  let(:run_one) { ReconEngine::History::RunInfo.new(1, "2026-01-15T09:00:00Z", "a" * 64, "cfg", 3, 0) }

  def entry(id, first_seen_run)
    ReconEngine::History::Entry.new("key-#{id}", id, "missing_in_target", true, 100, first_seen_run,
                                    "2026-01-15T09:00:00Z")
  end

  def summary(previous: run_one)
    described_class.new(database: "history.sqlite3", run: run_two, previous: previous, rerun: false,
                        opened: [entry("brk_new", 2)], still_open: [entry("brk_old", 1), entry("brk_older", 1)],
                        resolved: [], schema_changes: [])
  end

  def cluster(*ids) = Struct.new(:break_ids).new(ids)

  it "says how long a cluster's breaks have been open" do
    expect(summary.age_text(cluster("brk_new"))).to eq("new this run")
    expect(summary.age_text(cluster("brk_old", "brk_older"))).to eq("open since run 1 (2 runs)")
    expect(summary.age_text(cluster("brk_old", "brk_new"))).to eq("1 open since run 1 (2 runs), 1 new this run")
  end

  it "stays quiet about age on a first run, where everything is new" do
    expect(summary(previous: nil).age_text(cluster("brk_new"))).to be_nil
  end

  it "points at the oldest open break" do
    expect(summary.oldest).to have_attributes(first_seen_run: 1, key: "key-brk_old")
  end

  describe ReconEngine::History::SchemaChange do
    it "lists removed, added and retyped columns, and ignores a blank sample" do
      was = { "amount" => "decimal", "memo" => "string", "fee" => "integer", "note" => "string" }
      now = { "amount" => "string", "fee" => "decimal", "note" => "unknown", "batch_id" => "string" }

      expect(described_class.between("warehouse", was, now).map(&:describe)).to eq(
        [%(warehouse: column "memo" removed),
         %(warehouse: column "batch_id" added (string)),
         %(warehouse: column "amount" changed from decimal to string),
         %(warehouse: column "fee" changed from integer to decimal)]
      )
    end

    it "has nothing to say when a schema was never inferred" do
      expect(described_class.between("ledger", {}, { "amount" => "decimal" })).to be_empty
    end
  end
end
