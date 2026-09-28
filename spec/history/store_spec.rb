# frozen_string_literal: true

RSpec.describe ReconEngine::History::Store do
  let(:dir) { Dir.mktmpdir }
  let(:db) { File.join(dir, "history.sqlite3") }
  let(:generator) { ReconEngine::Generator.new(seed: 11, rows: 300) }
  let(:day_one) { generator.write(File.join(dir, "day1")) }
  let(:day_two) { generator.write_next_day(File.join(dir, "day2")) }

  after { FileUtils.remove_entry(dir) }

  def reconcile(manifest, settings = config(agent_enabled: false), db: self.db)
    ReconEngine::Run.call(ledger_path: manifest["paths"]["ledger"], warehouse_path: manifest["paths"]["warehouse"],
                          config: settings, db: db)
  end

  def keys_of(entries, type) = entries.select { |entry| entry.type == type }.map(&:key)

  it "starts every break ageing on the first run" do
    report  = reconcile(day_one)
    history = report.history

    expect(history).to be_first_run
    expect(history.opened.length).to eq(report.break_count)
    expect(history.still_open + history.resolved).to be_empty
  end

  it "sorts the next day's breaks into new, still open and resolved" do
    reconcile(day_one)
    history = reconcile(day_two).history
    changes = day_two["changes"]

    expect(keys_of(history.resolved, "duplicate").length).to eq(changes["replays_removed"])
    expect(keys_of(history.resolved, "missing_in_target"))
      .to match_array(changes["backfilled"].map { |id| "missing_in_target|txn:#{id}" })
    expect(keys_of(history.opened, "missing_in_target"))
      .to match_array(changes["new_missing"].map { |id| "missing_in_target|txn:#{id}" })
    expect(keys_of(history.opened, "value_mismatch")).to be_empty
  end

  # The warehouse is reshuffled overnight, so the same breaks come back on
  # other row numbers and with other ids.
  it "follows a break across a change of row numbers" do
    first_ids = reconcile(day_one).breaks.map(&:id)
    history   = reconcile(day_two).history
    moved     = history.still_open.reject { |entry| first_ids.include?(entry.break_id) }

    expect(moved).not_to be_empty
    expect(moved).to all(have_attributes(first_seen_run: 1))
  end

  it "ages a break from the start of its current streak" do
    reconcile(day_one)
    reconcile(day_two)
    history = reconcile(day_one).history # the replays are back

    still_missing = history.still_open.find { |entry| entry.type == "missing_in_target" }
    expect(still_missing.runs_open(history.run.number)).to eq(3)
    expect(keys_of(history.opened, "missing_in_target"))
      .to match_array(day_two["changes"]["backfilled"].map { |id| "missing_in_target|txn:#{id}" })
  end

  it "does not record the same inputs twice" do
    reconcile(day_one)
    history = reconcile(day_one).history

    expect(history).to be_rerun
    expect(history.run.number).to eq(1)
    expect(described_class.open(db, &:run_count)).to eq(1)
  end

  it "reports a column that appeared since the previous run" do
    reconcile(day_one)
    history = reconcile(day_two).history

    expect(history.schema_changes.map(&:to_h)).to contain_exactly(
      { source: "warehouse", kind: "column_added", column: "batch_id", from: nil, to: "string" }
    )
  end

  it "says when the settings changed between runs" do
    reconcile(day_one)
    history = reconcile(day_one, config(agent_enabled: false, tolerance_cents: 5)).history

    expect(history.run.number).to eq(2)
    expect(history).to be_settings_changed
  end

  it "keeps history out of the fingerprint" do
    expect(reconcile(day_one).deterministic_fingerprint).to eq(reconcile(day_one, db: nil).deterministic_fingerprint)
  end

  it "puts the comparison in the JSON report" do
    reconcile(day_one)
    payload = JSON.parse(ReconEngine::Reporting::JsonReport.generate(reconcile(day_two)))

    expect(payload["history"]).to include("run_number" => 2, "rerun" => false)
    expect(payload.dig("history", "new", "count")).to be_positive
    expect(payload["clusters"]).to all(include("history"))
  end

  describe "a file it cannot use" do
    it "refuses a database written by a newer version" do
      require "sqlite3"
      SQLite3::Database.new(db).tap { |file| file.execute("PRAGMA user_version = 99") }.close

      expect { reconcile(day_one) }.to raise_error(ReconEngine::HistoryError, /newer recon-engine/)
    end

    it "names the file when it is not a database at all" do
      File.write(db, "not a database, just some text that is long enough to have a header")

      expect { reconcile(day_one) }.to raise_error(ReconEngine::HistoryError, /#{Regexp.escape(db)}/)
    end

    it "says how to install sqlite3 when the gem is missing" do
      allow(ReconEngine::History).to receive(:require).with("sqlite3").and_raise(LoadError)

      expect { ReconEngine::History.load_driver }.to raise_error(ReconEngine::HistoryError, /gem install sqlite3/)
    end
  end
end
