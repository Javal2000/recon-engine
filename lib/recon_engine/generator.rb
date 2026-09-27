# frozen_string_literal: true

require "fileutils"

module ReconEngine
  # Produces a synthetic ledger and warehouse with faults injected on purpose,
  # plus a manifest recording exactly which faults went where.
  #
  # All data in this project comes from here, and the manifest doubles as the
  # answer key for the golden-set evaluation in spec/eval. A given seed always
  # produces byte-identical files.
  class Generator
    STATUSES   = %w[POSTED SETTLED PENDING].freeze
    CURRENCIES = %w[USD USD USD EUR CAD].freeze # weighted: mostly USD
    HEADERS    = %w[txn_id account_id posted_date amount currency status].freeze

    # Big enough that clustering visibly matters, small enough to check by hand.
    DEFAULT_FAULTS = {
      missing: 14,        # dropped between systems
      duplicated: 9,      # replayed by an at-least-once load
      timing: 26,         # T+1 settlement
      rounding: 18,       # one cent lost to precision
      material: 7,        # a different number altogether
      status: 6,          # status changed in transit
      orphan: 5,          # invented downstream
      split: 4,           # one deposit arrives as three legs
      composite_only: 120 # txn_id absent downstream
    }.freeze

    # How a correct analyst would classify each fault. Split and composite-only
    # rows should reconcile silently, so they carry a note instead.
    EXPECTED = {
      missing: "MISSING_IN_TARGET", duplicated: "DUPLICATE_IN_TARGET", timing: "TIMING_DIFFERENCE",
      rounding: "ROUNDING", material: "GENUINE_DISCREPANCY", status: "GENUINE_DISCREPANCY",
      orphan: "GENUINE_DISCREPANCY"
    }.freeze

    NOTES = {
      split: "should match via N-to-one, not produce a break",
      composite_only: "should match via composite key, not produce a break"
    }.freeze

    def initialize(seed: 42, rows: 2000, accounts: 10, days: 10,
                   start_date: Date.new(2026, 1, 5), faults: {})
      @seed       = seed
      @rows       = rows
      @accounts   = accounts
      @days       = days
      @start_date = start_date
      @faults     = DEFAULT_FAULTS.merge(faults)
      @rng        = Random.new(seed)
    end

    attr_reader :seed

    # Writes ledger.csv, warehouse.csv and manifest.json into dir.
    # @return [Hash] the manifest
    def write(dir)
      FileUtils.mkdir_p(dir)
      ledger, warehouse, manifest = build

      write_csv(File.join(dir, "ledger.csv"), ledger)
      write_csv(File.join(dir, "warehouse.csv"), warehouse)
      File.write(File.join(dir, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n")

      manifest.merge(
        "paths" => {
          "ledger" => File.join(dir, "ledger.csv"),
          "warehouse" => File.join(dir, "warehouse.csv"),
          "manifest" => File.join(dir, "manifest.json")
        }
      )
    end

    # @return [Array(Array<Hash>, Array<Hash>, Hash)]
    def build
      ledger = Array.new(@rows) { |i| ledger_row(i) }
      assignments = assign_faults
      warehouse, injected = derive_warehouse(ledger, assignments)

      # Shuffled so nothing can pass by relying on both files sharing an order.
      warehouse = warehouse.shuffle(random: @rng)

      [ledger, warehouse, manifest_for(ledger, warehouse, injected)]
    end

    private

    def ledger_row(index)
      date = @start_date + @rng.rand(@days)
      {
        "txn_id" => format("TXN-%06d", index + 1),
        "account_id" => format("ACC-%04d", @rng.rand(@accounts) + 1),
        "posted_date" => date.iso8601,
        "amount" => Money.format(random_cents),
        "currency" => CURRENCIES[@rng.rand(CURRENCIES.length)],
        "status" => STATUSES[@rng.rand(STATUSES.length)]
      }
    end

    # Amounts between $1.00 and $9,999.99, signed. Never zero: a zero-amount
    # transaction reconciles trivially and would only dilute the demo.
    def random_cents
      magnitude = @rng.rand(100..999_999)
      @rng.rand(10) < 4 ? -magnitude : magnitude
    end

    # Each ledger row gets at most one fault, so no row is both dropped and
    # duplicated and the manifest stays unambiguous.
    def assign_faults
      pool = (0...@rows).to_a.shuffle(random: @rng)
      @faults.each_with_object({}) do |(kind, count), assignments|
        next if kind == :orphan # orphans are invented, not derived from a row

        assignments[kind] = pool.shift(count)
      end
    end

    def derive_warehouse(ledger, assignments)
      fault_of  = assignments.flat_map { |kind, indexes| indexes.map { |index| [index, kind] } }.to_h
      injected  = []
      warehouse = []

      ledger.each_with_index do |row, index|
        kind = fault_of[index]
        warehouse.concat(kind ? downstream_rows(kind, row) : [row.dup])
        injected << fault(kind, row) if kind
      end

      @faults[:orphan].times do |i|
        row = orphan_row(i)
        warehouse << row
        injected << fault(:orphan, row)
      end

      [warehouse, injected]
    end

    def orphan_row(index)
      {
        "txn_id" => format("WHS-ORPHAN-%03d", index + 1),
        "account_id" => format("ACC-%04d", @rng.rand(@accounts) + 1),
        "posted_date" => (@start_date + @rng.rand(@days)).iso8601,
        "amount" => Money.format(random_cents),
        "currency" => "USD",
        "status" => "POSTED"
      }
    end

    # Split `cents` into `parts` integer legs that sum back to exactly `cents`.
    # The legs must sum exactly or the N-to-one matcher has nothing to find, and
    # they must differ from each other or two identical legs on the same account
    # and date collide as a duplicate the manifest never injected.
    def split_amount(cents, parts)
      sign      = cents.negative? ? -1 : 1
      magnitude = cents.abs
      raise ArgumentError, "cannot split #{cents} into #{parts} distinct legs" if magnitude < parts * 2

      # Random interior cut points give unequal legs; sorting the cuts and taking
      # consecutive differences guarantees the pieces still sum to the whole.
      20.times do
        cuts = Array.new(parts - 1) { @rng.rand(1...magnitude) }.sort
        legs = ([0] + cuts + [magnitude]).each_cons(2).map { |low, high| (high - low) * sign }
        return legs if legs.uniq.length == parts && legs.none?(&:zero?)
      end

      # Deterministic fallback, still distinct and still exact.
      base = magnitude / (parts + 1)
      legs = Array.new(parts - 1) { |i| (base + i + 1) * sign }
      legs << ((magnitude * sign) - legs.sum)
      legs
    end

    # What the warehouse receives for a ledger row carrying this fault.
    def downstream_rows(kind, row)
      case kind
      when :missing        then []
      when :duplicated     then [row.dup, row.dup]
      when :timing         then [row.merge("posted_date" => (Date.iso8601(row["posted_date"]) + 1).iso8601)]
      when :rounding       then [with_cents(row) { |cents| cents + (cents.negative? ? -1 : 1) }]
      when :material       then [with_cents(row) { |cents| cents + 5_000 }]
      when :status         then [row.merge("status" => (STATUSES - [row["status"]]).first)]
      when :split          then split_legs(row)
      when :composite_only then [row.merge("txn_id" => "")]
      end
    end

    def with_cents(row)
      row.merge("amount" => Money.format(yield(Money.to_cents(row["amount"]))))
    end

    def split_legs(row)
      split_amount(Money.to_cents(row["amount"]), 3).map do |leg_cents|
        row.merge("txn_id" => "", "amount" => Money.format(leg_cents))
      end
    end

    def fault(kind, row)
      {
        "kind" => kind.to_s,
        "txn_id" => row["txn_id"],
        "account_id" => row["account_id"],
        "posted_date" => row["posted_date"],
        "amount" => row["amount"],
        "expected_classification" => EXPECTED[kind],
        "note" => NOTES[kind]
      }.compact
    end

    def manifest_for(ledger, warehouse, injected)
      {
        "generator" => {
          "seed" => @seed,
          "ledger_rows" => ledger.length,
          "warehouse_rows" => warehouse.length,
          "accounts" => @accounts,
          "days" => @days,
          "start_date" => @start_date.iso8601
        },
        "fault_counts" => injected.map { |f| f["kind"] }.tally.sort.to_h,
        "expected_classifications" => injected
                                      .filter_map { |f| f["expected_classification"] }
                                      .tally.sort.to_h,
        "faults" => injected.sort_by { |f| [f["kind"], f["txn_id"]] }
      }
    end

    def write_csv(path, rows)
      CSV.open(path, "w", write_headers: true, headers: HEADERS) do |csv|
        rows.each { |row| csv << HEADERS.map { |h| row[h] } }
      end
      path
    end
  end
end
