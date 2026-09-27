# frozen_string_literal: true

RSpec.describe "deterministic checks" do
  let(:cfg) { ReconEngine::Config.build }

  def breaks_from(check_class, ledger_rows, warehouse_rows, configuration = cfg)
    check_class.new(configuration).call(context_for(ledger_rows, warehouse_rows, configuration))
  end

  describe ReconEngine::Checks::Completeness do
    it "reports a ledger row that never arrived" do
      records = breaks_from(described_class, ledger(id: "TXN-1", amount: "50.00"), [])

      expect(records.map(&:type)).to eq([:missing_in_target])
      expect(records.first.magnitude_cents).to eq(5_000)
      expect(records.first.ledger_refs).to eq(["ledger:1"])
    end

    it "reports a warehouse row with no ledger counterpart" do
      records = breaks_from(described_class, [], warehouse(id: "TXN-9", amount: "50.00"))

      expect(records.map(&:type)).to eq([:orphan_in_target])
      expect(records.first.warehouse_refs).to eq(["warehouse:1"])
    end

    describe "duplicated keys" do
      let(:doubled) { warehouse({ id: "TXN-1", amount: "50.00" }, { id: "TXN-1", amount: "50.00" }) }

      it "leaves a duplicate's extra copy to the Duplicates check" do
        expect(breaks_from(described_class, ledger(id: "TXN-1", amount: "50.00"), doubled)).to be_empty
      end

      it "still reports one orphan when no copy of the key has a counterpart" do
        records = breaks_from(described_class, [], doubled)

        expect(records.map(&:type)).to eq([:orphan_in_target])
      end

      it "counts the surplus money once across both checks" do
        rows    = [ledger(id: "TXN-1", amount: "50.00"), doubled]
        records = [described_class, ReconEngine::Checks::Duplicates].flat_map { |check| breaks_from(check, *rows) }

        expect(records.select(&:row_level?).sum { |b| b.magnitude_cents.abs }).to eq(5_000)
      end
    end

    # The reason the timing window exists at all: without it this is two breaks
    # for one non-event.
    it "reports nothing for a T+1 settlement" do
      records = breaks_from(
        described_class,
        ledger(id: nil, date: "2026-03-01"),
        warehouse(id: nil, date: "2026-03-02")
      )

      expect(records).to be_empty
    end
  end

  describe ReconEngine::Checks::ControlTotals do
    it "is silent when the sums tie" do
      rows = [{ id: "TXN-1", amount: "10.00" }, { id: "TXN-2", amount: "-4.00" }]
      records = breaks_from(described_class, ledger(*rows), warehouse(*rows))

      expect(records).to be_empty
    end

    it "catches a value change that leaves every row matched" do
      records = breaks_from(
        described_class,
        ledger(id: "TXN-1", amount: "100.00"),
        warehouse(id: "TXN-1", amount: "90.00")
      )

      total = records.find { |r| r.type == :control_total_mismatch }
      expect(total.magnitude_cents).to eq(-1_000)
      expect(records.map(&:type)).not_to include(:row_count_mismatch)
    end

    it "reports a row count mismatch per partition" do
      records = breaks_from(
        described_class,
        ledger(id: "TXN-1", amount: "10.00"),
        warehouse({ id: "TXN-1", amount: "10.00" }, { id: "TXN-2", amount: "10.00" })
      )

      count_break = records.find { |r| r.type == :row_count_mismatch }
      expect(count_break.details[:delta]).to eq(1)
    end

    it "marks its breaks as aggregate so they are not double counted" do
      records = breaks_from(
        described_class,
        ledger(id: "TXN-1", amount: "100.00"),
        warehouse(id: "TXN-1", amount: "90.00")
      )

      expect(records).to all(satisfy { |r| r.level == :aggregate })
      expect(records).to all(satisfy { |r| !r.row_level? })
    end
  end

  describe ReconEngine::Checks::Duplicates do
    it "names the cause rather than the symptom" do
      rows = warehouse({ id: "TXN-1", amount: "20.00" }, { id: "TXN-1", amount: "20.00" })
      records = breaks_from(described_class, ledger(id: "TXN-1", amount: "20.00"), rows)

      expect(records.map(&:type)).to eq([:duplicate])
      expect(records.first.details[:occurrences]).to eq(2)
      expect(records.first.details[:source]).to eq("warehouse")
      # One surplus copy, so one unit of surplus money.
      expect(records.first.magnitude_cents).to eq(2_000)
    end

    it "detects duplicates upstream too" do
      rows = ledger({ id: "TXN-1" }, { id: "TXN-1" })
      records = breaks_from(described_class, rows, [])

      expect(records.first.details[:source]).to eq("ledger")
    end

    it "uses the composite key when there is no transaction id" do
      rows = warehouse(
        { id: nil, amount: "20.00", date: "2026-01-05" },
        { id: nil, amount: "20.00", date: "2026-01-05" }
      )
      records = breaks_from(described_class, [], rows)

      expect(records.length).to eq(1)
      expect(records.first.details[:occurrences]).to eq(2)
    end
  end

  describe ReconEngine::Checks::SchemaDrift do
    # Every case uses rows that reconcile perfectly; schema drift has to fire on
    # its own.
    let(:rows) { { id: "TXN-1", amount: "100.00" } }

    def drift_between(ledger_schema, warehouse_schema)
      described_class.new(cfg).call(
        context_for(ledger(rows), warehouse(rows), cfg,
                    ledger_schema: ledger_schema, warehouse_schema: warehouse_schema)
      )
    end

    it "is silent when both sources agree on every column" do
      schema = { "txn_id" => "string", "amount" => "decimal" }

      expect(drift_between(schema, schema)).to be_empty
    end

    # A Profile built from rows rather than a file has no schema to compare.
    it "is silent when a schema was never inferred" do
      expect(drift_between({}, { "amount" => "decimal" })).to be_empty
      expect(drift_between({ "amount" => "decimal" }, {})).to be_empty
    end

    it "reports a ledger column with no warehouse counterpart" do
      records = drift_between({ "amount" => "decimal", "memo" => "string" }, { "amount" => "decimal" })

      expect(records.map(&:type)).to eq([:schema_drift])
      expect(records.first.details[:kind]).to eq("column_missing")
      expect(records.first.details[:column]).to eq("memo")
    end

    it "reports a warehouse column the ledger does not have" do
      records = drift_between({ "amount" => "decimal" }, { "amount" => "decimal", "batch_id" => "string" })

      expect(records.first.details[:kind]).to eq("column_added")
      expect(records.first.details[:column]).to eq("batch_id")
    end

    # The case that motivates the check: a pipeline writing amounts into an
    # integer column truncates the cents, and every row still reconciles today.
    it "reports a column whose type narrowed in transit" do
      records = drift_between({ "amount" => "decimal" }, { "amount" => "integer" })

      expect(records.first.details[:kind]).to eq("type_changed")
      expect(records.first.details[:ledger_type]).to eq("decimal")
      expect(records.first.details[:warehouse_type]).to eq("integer")
    end

    # An all-blank sample says nothing about the column's type.
    it "does not call an uninferable column a type change" do
      expect(drift_between({ "amount" => "unknown" }, { "amount" => "decimal" })).to be_empty
      expect(drift_between({ "amount" => "decimal" }, { "amount" => "unknown" })).to be_empty
    end

    it "carries no dollars and stays out of the headline impact" do
      records = drift_between({ "amount" => "decimal" }, { "amount" => "integer" })

      expect(records.first.magnitude_cents).to eq(0)
      expect(records.first.level).to eq(:aggregate)
      expect(records.first.row_level?).to be(false)
    end

    # One pipeline change that drops three columns is one finding, not three.
    it "clusters by kind of drift rather than by column" do
      records  = drift_between(
        { "amount" => "decimal", "memo" => "string", "batch" => "string", "fx" => "decimal" },
        { "amount" => "integer" }
      )
      clusters = ReconEngine::Breaks::Clusterer.call(records)

      expect(records.length).to eq(4)
      expect(clusters.length).to eq(2)
      expect(clusters.map(&:count).sort).to eq([1, 3])
    end
  end

  describe ReconEngine::Checks::ValueLevel do
    it "records a sub-tolerance amount difference the matcher was allowed to absorb" do
      records = breaks_from(
        described_class,
        ledger(id: "TXN-1", amount: "10.00"),
        warehouse(id: "TXN-1", amount: "10.01")
      )

      expect(records.first.details[:fields]).to eq(["amount"])
      expect(records.first.details[:band]).to eq("sub_tolerance")
      expect(records.first.magnitude_cents).to eq(1)
    end

    it "bands a material difference separately" do
      records = breaks_from(
        described_class,
        ledger(id: "TXN-1", amount: "10.00"),
        warehouse(id: "TXN-1", amount: "60.00")
      )

      expect(records.first.details[:band]).to eq("material")
    end

    it "records a date shift on rows that matched by id" do
      records = breaks_from(
        described_class,
        ledger(id: "TXN-1", date: "2026-01-05"),
        warehouse(id: "TXN-1", date: "2026-01-06")
      )

      expect(records.first.details[:fields]).to eq(["posted_date"])
      expect(records.first.details[:band]).to eq("date_shifted")
      expect(records.first.details[:date_delta_days]).to eq(1)
    end

    it "records a status change on its own" do
      records = breaks_from(
        described_class,
        ledger(id: "TXN-1", status: "POSTED"),
        warehouse(id: "TXN-1", status: "REVERSED")
      )

      expect(records.first.details[:band]).to eq("status_only")
    end

    it "is silent when matched rows agree exactly" do
      records = breaks_from(
        described_class,
        ledger(id: "TXN-1"),
        warehouse(id: "TXN-1")
      )

      expect(records).to be_empty
    end

    it "compares the summed legs of an N-to-one match, not the individual rows" do
      records = breaks_from(
        described_class,
        ledger(id: nil, amount: "300.00"),
        warehouse(
          { id: nil, amount: "120.00" },
          { id: nil, amount: "100.00" },
          { id: nil, amount: "80.00" }
        )
      )

      expect(records).to be_empty
    end
  end

  describe ReconEngine::Breaks::BreakRecord do
    it "gives the same break the same id every time" do
      first  = breaks_from(ReconEngine::Checks::Completeness, ledger(id: "TXN-1"), [])
      second = breaks_from(ReconEngine::Checks::Completeness, ledger(id: "TXN-1"), [])

      expect(first.first.id).to eq(second.first.id)
      expect(first.first.id).to start_with("brk_")
    end

    it "gives different breaks different ids" do
      records = breaks_from(
        ReconEngine::Checks::Completeness,
        ledger({ id: "TXN-1", amount: "1.00" }, { id: "TXN-2", amount: "2.00" }),
        []
      )

      expect(records.map(&:id).uniq.length).to eq(2)
    end
  end
end
