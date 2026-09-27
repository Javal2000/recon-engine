# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2"

# No runtime dependencies beyond the standard library, so the demo runs
# straight after a clone. `csv` and `bigdecimal` are being moved out of the
# default gems in newer Rubies, so they are pinned explicitly.
gem "bigdecimal", "~> 3.1"
gem "csv", "~> 3.3"

group :development, :test do
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "rubocop", require: false
  gem "rubocop-rake", require: false
  gem "rubocop-rspec", require: false
  gem "simplecov", require: false
end
