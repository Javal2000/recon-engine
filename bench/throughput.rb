# frozen_string_literal: true

# Times the deterministic layer phase by phase on generated data.
#
#   rake bench                         # 10k and 100k ledger rows
#   BENCH_ROWS=1000000 rake bench      # any comma-separated sizes
#
# The agent is left out: its time is spent waiting on a model, not in Ruby.
# "Heap" is Ruby's own accounting of live objects with both files loaded and
# matched, which is the point where memory peaks.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "recon_engine"
require "benchmark"
require "objspace"

# Generates data at each size, times each phase, and prints a Markdown row.
class ThroughputBenchmark
  include ReconEngine

  HEADER = [
    "| Ledger rows | Profile | Load | Match | Check + cluster | Total | Rows/s | Heap | Breaks |",
    "|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
  ].freeze

  def initialize(sizes)
    @sizes  = sizes
    @config = Config.build(agent_enabled: false)
  end

  def run
    puts HEADER
    @sizes.each { |rows| Dir.mktmpdir("recon-bench") { |dir| puts measure(rows, dir) } }
  end

  private

  def measure(rows, dir)
    manifest = Generator.new(seed: 42, rows: rows).write(dir)
    sources  = %i[ledger warehouse].map { |name| Sources::CsvSource.new(manifest["paths"][name.to_s], name: name) }
    GC.start

    timings = {}
    timings[:profile] = Benchmark.realtime { @profiles = sources.map { |source| Sources::Profile.build(source) } }
    timings[:load]    = Benchmark.realtime { @rows = sources.map(&:to_a) }
    timings[:match]   = Benchmark.realtime { @matched = match(*@rows) }
    heap_mb = heap_megabytes
    timings[:check] = Benchmark.realtime { @breaks = Breaks::Clusterer.call(check_all).sum(&:count) }

    table_row(rows, timings, heap_mb)
  end

  def match(ledger, warehouse) = Matching::Engine.new(@config).call(ledger: ledger, warehouse: warehouse)

  def check_all
    context = Checks::Context.new(config: @config, match_result: @matched,
                                  ledger_profile: @profiles[0], warehouse_profile: @profiles[1],
                                  ledger_rows: @rows[0], warehouse_rows: @rows[1])
    Checks::Base.all.flat_map { |check| check.new(@config).call(context) }
  end

  def heap_megabytes
    GC.start
    ObjectSpace.memsize_of_all / 1024.0 / 1024
  end

  def table_row(rows, timings, heap_mb)
    total = timings.values.sum
    rate  = @rows.sum(&:length) / total
    cells = [group(rows), *timings.values_at(:profile, :load, :match, :check).map { |t| format("%.2fs", t) },
             format("%.2fs", total), group(rate.round), format("%.0f MB", heap_mb), @breaks]
    "| #{cells.join(" | ")} |"
  end

  def group(number) = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

ThroughputBenchmark.new(ENV.fetch("BENCH_ROWS", "10000,100000").split(",").map { |n| Integer(n) }).run
