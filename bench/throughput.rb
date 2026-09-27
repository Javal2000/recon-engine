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

include ReconEngine

sizes  = ENV.fetch("BENCH_ROWS", "10000,100000").split(",").map { |n| Integer(n) }
config = Config.build(agent_enabled: false)

puts "| Ledger rows | Profile | Load | Match | Check + cluster | Total | Rows/s | Heap | Breaks |"
puts "|---:|---:|---:|---:|---:|---:|---:|---:|---:|"

sizes.each do |rows|
  Dir.mktmpdir("recon-bench") do |dir|
    manifest  = Generator.new(seed: 42, rows: rows).write(dir)
    ledger    = Sources::CsvSource.new(manifest["paths"]["ledger"], name: :ledger)
    warehouse = Sources::CsvSource.new(manifest["paths"]["warehouse"], name: :warehouse)
    GC.start

    profiles = matched = context = nil
    ledger_rows = warehouse_rows = nil
    clusters = []

    timings = {
      profile: Benchmark.realtime { profiles = [Sources::Profile.build(ledger), Sources::Profile.build(warehouse)] },
      load: Benchmark.realtime { ledger_rows = ledger.to_a; warehouse_rows = warehouse.to_a },
      match: Benchmark.realtime do
        matched = Matching::Engine.new(config).call(ledger: ledger_rows, warehouse: warehouse_rows)
      end
    }

    GC.start
    heap_mb = ObjectSpace.memsize_of_all / 1024.0 / 1024

    timings[:check] = Benchmark.realtime do
      context = Checks::Context.new(config: config, match_result: matched,
                                    ledger_profile: profiles[0], warehouse_profile: profiles[1],
                                    ledger_rows: ledger_rows, warehouse_rows: warehouse_rows)
      breaks   = Checks::Base.all.flat_map { |check| check.new(config).call(context) }
      clusters = Breaks::Clusterer.call(breaks)
    end

    total = timings.values.sum
    rate  = (ledger_rows.length + warehouse_rows.length) / total
    puts format("| %<rows>s | %<p>.2fs | %<l>.2fs | %<m>.2fs | %<c>.2fs | %<t>.2fs | %<rate>s | %<heap>.0f MB | %<b>d |",
                rows: rows.to_s.reverse.scan(/\d{1,3}/).join(",").reverse,
                p: timings[:profile], l: timings[:load], m: timings[:match], c: timings[:check], t: total,
                rate: rate.round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse, heap: heap_mb,
                b: clusters.sum(&:count))
  end
end
