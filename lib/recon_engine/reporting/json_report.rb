# frozen_string_literal: true

module ReconEngine
  module Reporting
    # The machine-consumable report.
    #
    # Stable break ids, integer cents alongside formatted strings, and every
    # agent finding tagged with its provenance. A scheduler can compare
    # `deterministic_fingerprint` between runs to see whether anything changed.
    module JsonReport
      module_function

      def to_h(report)
        {
          schema_version: 1,
          engine_version: ReconEngine::VERSION,
          run: run_section(report),
          config: report.config.to_h.transform_values { |v| v.is_a?(Symbol) ? v.to_s : v },
          inputs: report.inputs,
          sources: { ledger: report.ledger_profile.to_report_h, warehouse: report.warehouse_profile.to_report_h },
          matching: report.match_result.to_report_h,
          summary: summary_section(report),
          agent: agent_section(report),
          clusters: report.clusters.map do |cluster|
            cluster.to_report_h.merge(finding: report.finding_for(cluster)&.to_report_h)
          end,
          breaks: report.breaks.map(&:to_report_h)
        }
      end

      def run_section(report)
        { started_at: report.started_at.iso8601, duration_seconds: report.duration_seconds.round(3),
          deterministic_fingerprint: report.deterministic_fingerprint }
      end

      def summary_section(report)
        {
          break_count: report.break_count,
          cluster_count: report.clusters.length,
          row_level_impact: Money.format(report.row_level_impact_cents),
          row_level_impact_cents: report.row_level_impact_cents,
          breaks_by_type: report.breaks_by_type,
          by_classification: report.classification_summary.transform_values do |v|
            v.merge(magnitude: Money.format(v[:magnitude_cents]))
          end
        }
      end

      def agent_section(report)
        { enabled: report.config.agent_enabled, provider: report.config.agent_provider.to_s,
          model_backed: report.model_backed_agent?, clusters_investigated: report.findings.length,
          degraded: report.findings.count(&:degraded), usage: report.agent_usage.to_report_h }
      end

      def generate(report)
        JSON.pretty_generate(to_h(report))
      end

      def write(report, path)
        require "fileutils"
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{generate(report)}\n")
        path
      end
    end
  end
end
