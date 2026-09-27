# frozen_string_literal: true

module ReconEngine
  # Scores a run's agent findings against the generator's manifest.
  #
  # Each injected fault produces a known break, and the manifest says how that
  # fault should be classified. A break counts as correct when the cluster it
  # landed in got that classification. Recall is reported per fault kind,
  # calibration compares stated confidence with how often the agent was right,
  # and coverage says how many breaks got a real answer at all, so a provider
  # that ran out of quota isn't mistaken for one that answered wrongly.
  class Evaluation
    # Where each fault kind shows up in the breaks. Orphans are picked out by
    # id, because every duplicate's surplus row also surfaces as an orphan.
    SCORED = {
      "missing" => { type: :missing_in_target },
      "orphan" => { type: :orphan_in_target, txn_prefix: "WHS-ORPHAN-" },
      "duplicated" => { type: :duplicate },
      "timing" => { type: :value_mismatch, band: "date_shifted" },
      "rounding" => { type: :value_mismatch, band: "sub_tolerance" },
      "material" => { type: :value_mismatch, band: "material" },
      "status" => { type: :value_mismatch, band: "status_only" }
    }.freeze

    CONFIDENCE_BANDS = [[0.0, 0.5], [0.5, 0.7], [0.7, 0.9], [0.9, 1.0]].freeze

    Outcome = Data.define(:kind, :expected, :actual, :confidence, :answered) do
      def correct? = actual == expected
    end

    attr_reader :manifest, :report

    def initialize(manifest:, report:)
      @manifest = manifest
      @report   = report
    end

    def outcomes
      @outcomes ||= SCORED.flat_map do |kind, location|
        expected = expected_classification(kind)
        breaks_at(location).map do |record|
          finding = finding_for_break[record.id]
          Outcome.new(kind: kind, expected: expected,
                      actual: finding&.classification || "NOT_INVESTIGATED",
                      confidence: finding&.confidence,
                      answered: !finding.nil? && !finding.degraded)
        end
      end
    end

    def recall_by_kind
      outcomes.group_by(&:kind).transform_values do |group|
        { expected: group.first.expected, breaks: group.length,
          correct: group.count(&:correct?), recall: ratio(group.count(&:correct?), group.length) }
      end
    end

    def overall_recall = ratio(outcomes.count(&:correct?), outcomes.length)

    # Share of scored breaks whose cluster got a non-degraded answer.
    def coverage = ratio(outcomes.count(&:answered), outcomes.length)

    # Only answered breaks carry a confidence worth judging. Expected
    # calibration error is the gap between stated confidence and observed
    # accuracy, averaged across bands and weighted by how many breaks fell in
    # each.
    def calibration
      answered = outcomes.select(&:answered)
      bands = CONFIDENCE_BANDS.filter_map do |low, high|
        members = answered.select { |o| o.confidence >= low && (o.confidence < high || high == 1.0) }
        next if members.empty?

        { band: "#{low}-#{high}", breaks: members.length,
          mean_confidence: (members.sum(&:confidence) / members.length).round(3),
          accuracy: ratio(members.count(&:correct?), members.length) }
      end
      error = bands.sum { |b| b[:breaks] * (b[:mean_confidence] - b[:accuracy]).abs }
      { bands: bands, expected_calibration_error: answered.empty? ? nil : (error / answered.length).round(3) }
    end

    def to_h
      {
        provider: report.config.agent_provider.to_s,
        models: report.findings.map(&:model).uniq.compact,
        model_backed: report.model_backed_agent?,
        dataset: manifest.fetch("generator").slice("seed", "ledger_rows", "warehouse_rows"),
        clusters: report.clusters.length,
        clusters_investigated: report.findings.length,
        scored_breaks: outcomes.length,
        overall_recall: overall_recall,
        coverage: coverage,
        recall_by_kind: recall_by_kind,
        calibration: calibration,
        usage: report.agent_usage.to_report_h
      }
    end

    def to_markdown
      lines = ["| Fault | Expected | Breaks | Correct | Recall |", "|---|---|---:|---:|---:|"]
      recall_by_kind.each do |kind, row|
        lines << "| #{kind} | `#{row[:expected]}` | #{row[:breaks]} | #{row[:correct]} | #{percent(row[:recall])} |"
      end
      lines << "| **all** | | #{outcomes.length} | #{outcomes.count(&:correct?)} | **#{percent(overall_recall)}** |"
      lines.join("\n")
    end

    private

    def expected_classification(kind)
      manifest.fetch("faults").find { |f| f["kind"] == kind }&.fetch("expected_classification")
    end

    def breaks_at(location)
      report.breaks.select do |record|
        record.type == location[:type] &&
          (location[:band].nil? || record.details[:band] == location[:band]) &&
          (location[:txn_prefix].nil? || record.details[:txn_id].to_s.start_with?(location[:txn_prefix]))
      end
    end

    def finding_for_break
      @finding_for_break ||= report.clusters.each_with_object({}) do |cluster, index|
        finding = report.finding_for(cluster)
        cluster.break_ids.each { |id| index[id] = finding } if finding
      end
    end

    def ratio(part, whole) = whole.zero? ? 0.0 : (part.to_f / whole).round(3)
    def percent(value)     = format("%.0f%%", value * 100)
  end
end
