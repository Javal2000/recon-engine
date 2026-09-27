# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = "--tag ~eval"
end

desc "Run the golden-set agent evaluations (tagged :eval)"
RSpec::Core::RakeTask.new(:eval) do |t|
  t.rspec_opts = "--tag eval"
end

desc "Generate synthetic data and reconcile it end to end"
task :demo do
  # `ruby bin/recon` rather than `bin/recon`, so it also works on Windows.
  sh(RbConfig.ruby, "bin/recon", "demo")
end

desc "Time the deterministic layer (BENCH_ROWS=10000,100000 by default)"
task :bench do
  ruby "bench/throughput.rb"
end

task default: %i[spec eval]
