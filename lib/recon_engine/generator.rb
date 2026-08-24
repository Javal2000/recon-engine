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
      missing: 14,   # dropped between systems           -> MISSING_IN_TARGET
      duplicated: 9,    # replayed by an at-least-once load  -> DUPLICATE_IN_TARGET
      timing: 26,   # T+1 settlement                     -> TIMING_DIFFERENCE
      rounding: 18,   # one cent lost to precision         -> ROUNDING
      material: 7,    # a genuinely different number       -> GENUINE_DISCREPANCY
      status: 6,    # status changed in transit          -> GENUINE_DISCREPANCY
      orphan: 5,    # invented downstream                -> GENUINE_DISCREPANCY
      split: 4,    # one deposit arrives as N legs      -> matches, no break
      composite_only: 120  # txn_id absent downstream           -> matches via composite
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
      fault_of = {}
      assignments.each { |kind, indexes| indexes.each { |i| fault_of[i] = kind } }

      injected = []
      warehouse = []

      ledger.each_with_index do |row, index|
        case fault_of[index]
        when :missing
          injected << fault(:missing, row, "MISSING_IN_TARGET")
        when :duplicated
          warehouse << row.dup
          warehouse << row.dup
          injected << fault(:duplicated, row, "DUPLICATE_IN_TARGET")
        when :timing
          shifted = row.merge("posted_date" => (Date.iso8601(row["posted_date"]) + 1).iso8601)
          warehouse << shifted
          injected << fault(:timing, row, "TIMING_DIFFERENCE")
        when :rounding
          cents = Money.to_cents(row["amount"])
          warehouse << row.merge("amount" => Money.format(cents + (cents.negative? ? -1 : 1)))
          injected << fault(:rounding, row, "ROUNDING")
        when :material
          cents = Money.to_cents(row["amount"])
          warehouse << row.merge("amount" => Money.format(cents + 5_000))
          injected << fault(:material, row, "GENUINE_DISCREPANCY")
        when :status
          other = (STATUSES - [row["status"]]).first
          warehouse << row.merge("status" => other)
          injected << fault(:status, row, "GENUINE_DISCREPANCY")
        when :split
          legs = split_amount(Money.to_cents(row["amount"]), 3)
          legs.each do |leg_cents|
            warehouse << row.merge("txn_id" => "", "amount" => Money.format(leg_cents))
          end
          injected << fault(:split, row, nil, note: "should match via N-to-one, not produce a break")
        when :composite_only
          warehouse << row.merge("txn_id" => "")
          injected << fault(:composite_only, row, nil, note: "should match via composite key, not produce a break")
        else
          warehouse << row.dup
        end
      end

      @faults[:orphan].times do |i|
        row = orphan_row(i)
        warehouse << row
        injected << fault(:orphan, row, "GENUINE_DISCREPANCY")
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

    def fault(kind, row, expected_classification, note: nil)
      {
        "kind" => kind.to_s,
        "txn_id" => row["txn_id"],
        "account_id" => row["account_id"],
        "posted_date" => row["posted_date"],
        "amount" => row["amount"],
        "expected_classification" => expected_classification,
        "note" => note
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
