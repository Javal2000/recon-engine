# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"
require "csv"
require "date"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "time"
require "tmpdir"

module ReconEngine
  # Base class for every error this library raises deliberately.
  class Error < StandardError
  end

  # Raised when an input file does not look like what we were promised.
  class InputError < Error
  end

  # Raised when the agent layer cannot produce a schema-valid finding.
  class AgentError < Error
  end

  # Raised when an LLM provider is misconfigured or unreachable.
  class ProviderError < Error
  end

  # Raised when a provider's quota won't reset within the run, so retrying is
  # pointless.
  class QuotaExhausted < ProviderError
  end

  # Raised when the run-history database can't be opened or written.
  class HistoryError < Error
  end
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
require "recon_engine/breaks/attribution"
require "recon_engine/checks/base"
require "recon_engine/checks/completeness"
require "recon_engine/checks/control_totals"
require "recon_engine/checks/duplicates"
require "recon_engine/checks/schema_drift"
require "recon_engine/checks/value_level"
require "recon_engine/llm/usage"
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
require "recon_engine/history/identity"
require "recon_engine/history/summary"
require "recon_engine/history/store"
require "recon_engine/reporting/report"
require "recon_engine/reporting/terminal_text"
require "recon_engine/reporting/cli_history"
require "recon_engine/reporting/cli_report"
require "recon_engine/reporting/json_report"
require "recon_engine/reporting/html_report"
require "recon_engine/generator"
require "recon_engine/generator/next_day"
require "recon_engine/evaluation"
require "recon_engine/run"
require "recon_engine/cli"
