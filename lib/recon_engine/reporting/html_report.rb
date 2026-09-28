# frozen_string_literal: true

require "erb"

module ReconEngine
  module Reporting
    # The report as one self-contained HTML page: no scripts and no external
    # assets, so it can be attached to a ticket or opened offline. Everything
    # that came from a model or an input file is escaped, because an agent's
    # explanation is text nobody on this side wrote.
    class HtmlReport
      TEMPLATE = File.join(__dir__, "html_report.html.erb")

      TONES = {
        "EXPLAINED" => "ok", "TIMING_DIFFERENCE" => "calm", "ROUNDING" => "calm",
        "MISSING_IN_TARGET" => "warn", "DUPLICATE_IN_TARGET" => "warn",
        "GENUINE_DISCREPANCY" => "bad", "SCHEMA_DRIFT" => "info"
      }.freeze

      def self.write(report, path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, new(report).render)
      end

      def initialize(report)
        @report = report
      end

      def render
        ERB.new(File.read(TEMPLATE, encoding: "UTF-8"), trim_mode: "-").result(binding)
      end

      private

      attr_reader :report

      def h(text)       = ERB::Util.html_escape(text.to_s)
      def money(cents)  = Money.humanize(cents)
      def percent(part) = format("%.1f%%", part * 100)
      def tone(label)   = TONES.fetch(label, "muted")
      def group(number) = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

      def status_text
        return "Reconciled clean" if report.clean?

        "#{group(report.break_count)} breaks in #{report.clusters.length} causes"
      end

      # Bars are scaled to the largest bucket; a bucket worth $0 still shows its
      # break count, since a day-late feed can be the most important line.
      def money_buckets
        summary = report.classification_summary
        largest = summary.values.map { |row| row[:magnitude_cents] }.max.to_i
        summary.map do |label, row|
          width = largest.zero? ? 0 : (100.0 * row[:magnitude_cents] / largest).round(1)
          row.merge(label: label, width: width)
        end
      end

      def explained_count = report.clusters.count(&:explained?)

      def agent_text
        return "disabled" unless report.config.agent_enabled

        models  = report.findings.map(&:model).uniq.compact.join(", ")
        backing = report.model_backed_agent? ? models : "offline rule table"
        "#{backing}, #{report.findings.length} causes investigated"
      end

      def signature_text(cluster)
        cluster.signature.map { |key, value| "#{key}=#{Array(value).join("+")}" }.join(" ")
      end

      def attribution_value(attribution, value)
        return money(value) if attribution.measure == :cents

        "#{format("%+d", value)} row#{"s" unless value.abs == 1}"
      end

      def usage_text
        usage = report.agent_usage
        return nil unless usage.calls.positive?

        "#{usage.calls} model calls, #{group(usage.total_tokens)} tokens, " \
          "#{format("%.1f", usage.latency_ms / 1000.0)}s in the model"
      end
    end
  end
end
