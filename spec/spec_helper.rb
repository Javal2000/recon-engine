# frozen_string_literal: true

# Coverage is measured when COVERAGE is set, which CI does for the main spec
# run. The golden-set run exercises a narrower slice and isn't held to it.
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
    # A little under the measured 95.6% / 79.8%, so it catches a regression
    # without failing on the small differences between Ruby versions.
    minimum_coverage line: 94, branch: 77
  end
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "recon_engine"
require "tmpdir"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand(config.seed)

  # Golden-set evals are slower and cost money against a hosted provider, so
  # `rake spec` skips them and `rake eval` runs only them.
  config.define_derived_metadata(file_path: %r{/spec/eval/}) do |metadata|
    metadata[:eval] = true
  end

  config.include(Factories)
end
