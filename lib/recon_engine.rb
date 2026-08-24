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
require "recon_engine/llm/client"
require "recon_engine/llm/offline"
require "recon_engine/llm/http_provider"
require "recon_engine/llm/gemini"
require "recon_engine/llm/anthropic"
require "recon_engine/llm/openai"
require "recon_engine/llm/ollama"
require "recon_engine/agent/schema"
require "recon_engine/agent/tools"
require "recon_engine/agent/prompt"
require "recon_engine/agent/finding"
require "recon_engine/agent/investigator"
require "recon_engine/reporting/report"
require "recon_engine/reporting/cli_report"
require "recon_engine/reporting/json_report"
require "recon_engine/generator"
require "recon_engine/run"
require "recon_engine/cli"
