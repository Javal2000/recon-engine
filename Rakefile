# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = "--tag ~eval"
end

desc "Run the golden-set agent evaluations (tagged :eval)"
RSpec::Core::RakeTask.new(:eval) do |t|
  t.rspec_opts = "--tag eval"
end

# `ruby bin/recon` rather than `bin/recon`, so it also works on Windows. Exit 1
# means breaks were found, which is the whole point of the demo, so only a
# tool error (exit 2) fails the task.
def recon(*args)
  sh(RbConfig.ruby, "bin/recon", *args) do |_ok, status|
    abort("recon #{args.first} failed with exit #{status.exitstatus}") if status.exitstatus > 1
  end
end

desc "Generate synthetic data and reconcile it end to end"
task :demo do
  recon("demo")
end

namespace :demo do
  desc "Reconcile a day of books, then the next day, into one history file"
  task :history do
    db = "out/history.sqlite3"
    rm_f db
    recon("demo", "--db", db, "--quiet")
    recon("demo", "--next-day", "--db", db)
  end
end

desc "Time the deterministic layer (BENCH_ROWS=10000,100000 by default)"
task :bench do
  ruby "bench/throughput.rb"
end

task default: %i[spec eval]
