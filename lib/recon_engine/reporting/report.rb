# frozen_string_literal: true

module ReconEngine
  module Reporting
    # Everything one reconciliation run produced.
    #
    # #deterministic_fingerprint hashes the inputs, the deterministic settings
    # and every break, and leaves out timestamps, durations, hostnames and agent
    # findings. Two runs over the same bytes share a fingerprint even when a real
    # model wrote different explanations for them.
    class Report
      FIELDS = %i[config inputs ledger_profile warehouse_profile match_result breaks clusters
                  findings started_at duration_seconds history].freeze

      attr_reader(*FIELDS)

      # history is a History::Summary when the run was recorded with --db.
      def initialize(config:, inputs:, ledger_profile:, warehouse_profile:, match_result:,
                     breaks:, clusters:, findings:, started_at:, duration_seconds:, history: nil)
        @config            = config
        @inputs            = inputs
        @ledger_profile    = ledger_profile
        @warehouse_profile = warehouse_profile
        @match_result      = match_result
        @breaks            = breaks
        @clusters          = clusters
        @findings          = findings
        @started_at        = started_at
        @duration_seconds  = duration_seconds
        @history           = history
      end

      # A copy with some fields replaced, like Data#with.
      def with(**changes)
        self.class.new(**FIELDS.to_h { |name| [name, public_send(name)] }, **changes)
      end

      def findings_by_cluster
        @findings_by_cluster ||= findings.to_h { |f| [f.cluster_id, f] }
      end

      def finding_for(cluster) = findings_by_cluster[cluster.id]

      def break_count = breaks.length

      # Headline money at risk: row-level breaks only. Aggregate breaks (control
      # totals, row counts) describe the same dollars from a different angle and
      # would double-count if summed in.
      def row_level_impact_cents
        breaks.select(&:row_level?).sum { |b| b.magnitude_cents.abs }
      end

      def breaks_by_type
        breaks.map { |b| b.type.to_s }.tally.sort_by { |_type, count| -count }.to_h
      end

      def classification_summary
        grouped = clusters.group_by do |cluster|
          finding_for(cluster)&.classification || (cluster.explained? ? "EXPLAINED" : "NOT_INVESTIGATED")
        end
        summary = grouped.transform_values do |group|
          { clusters: group.length, breaks: group.sum(&:count),
            magnitude_cents: group.sum { |c| c.magnitude_cents.abs } }
        end
        summary.sort_by { |_classification, row| -row[:magnitude_cents] }.to_h
      end

      def clean?
        breaks.empty?
      end

      def deterministic_fingerprint
        payload = JSON.generate({
                                  config: config.deterministic_digest,
                                  inputs: inputs.map { |i| [i[:role], i[:digest]] }.sort,
                                  matching: match_result.to_report_h,
                                  breaks: breaks.map(&:id).sort
                                })
        Digest::SHA256.hexdigest(payload)
      end

      def agent_ran? = findings.any?

      def model_backed_agent?
        findings.any?(&:model_backed)
      end

      def agent_usage
        findings.map(&:usage).reduce(LLM::Usage.zero, :+)
      end
    end
  end
end
