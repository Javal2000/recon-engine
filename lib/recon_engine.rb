# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"
require "csv"
require "date"
require "digest"
require "json"
require "optparse"
require "set"
require "time"

module ReconEngine
  # Base class for every error this library raises deliberately.
  Error = Class.new(StandardError)

  # Raised when an input file does not look like what we were promised.
  InputError      = Class.new(Error)
  # Raised when the agent layer cannot produce a schema-valid finding.
  AgentError      = Class.new(Error)
  # Raised when an LLM provider is misconfigured or unreachable.
  ProviderError   = Class.new(Error)
end

require "recon_engine/version"
require "recon_engine/money"
require "recon_engine/transaction"
require "recon_engine/config"
require "recon_engine/sources/csv_source"
require "recon_engine/sources/profile"
require "recon_engine/matching/match_set"
require "recon_engine/matching/result"
require "recon_engine/matching/engine"
require "recon_engine/breaks/break_record"
require "recon_engine/breaks/cluster"
require "recon_engine/breaks/clusterer"
require "recon_engine/checks/base"
require "recon_engine/checks/completeness"
require "recon_engine/checks/control_totals"
require "recon_engine/checks/duplicates"
require "recon_engine/checks/schema_drift"
require "recon_engine/checks/value_level"
require "recon_engine/generator"
