# frozen_string_literal: true

module ReconEngine
  module Reporting
    # The human-facing report: whether it tied, how much money is involved, the
    # likely causes, and only then individual rows. Clusters lead and raw breaks
    # are summarised.
    class CliReport
      WIDTH = 78

      # ANSI colour, suppressed when stdout is not a TTY so that piping to a file
      # or capturing in CI does not fill the output with escape codes.
      COLORS = { red: 31, green: 32, yellow: 33, blue: 34, grey: 90 }.freeze

      # Unicode glyphs when the terminal can render them, ASCII otherwise. A
      # Windows console on the legacy code page turns "·" into mojibake.
      GLYPHS = {
        unicode: { sep: "·", ellipsis: "…", arrow: "→", dash: "—" },
        ascii: { sep: "|", ellipsis: "...", arrow: "->", dash: "--" }
      }.freeze

      # Agent explanations are free text written by a model, and models emit
      # em-dashes and curly quotes freely. Transliterating at the very end
      # catches whatever the provider decided to send.
      TRANSLITERATIONS = {
        "—" => "--", "–" => "-", "·" => "|", "…" => "...", "→" => "->",
        "“" => '"', "”" => '"', "‘" => "'", "’" => "'", "•" => "*", " " => " "
      }.freeze

      def self.unicode_terminal?
        encoding = $stdout.external_encoding || Encoding.default_external
        encoding.to_s.match?(/UTF-8/i)
      rescue StandardError
        false
      end

      def initialize(report, color: $stdout.tty?, unicode: self.class.unicode_terminal?)
        @report = report
        @color  = color
        @glyphs = GLYPHS.fetch(unicode ? :unicode : :ascii)
      end

      def render
        sections = [
          header,
          sources_section,
          matching_section,
          summary_section,
          clusters_section,
          footer
        ]
        output = "#{sections.compact.join("\n")}\n"
        @glyphs.equal?(GLYPHS[:ascii]) ? asciify(output) : output
      end

      private

      attr_reader :report

      def sep      = @glyphs[:sep]
      def ellipsis = @glyphs[:ellipsis]
      def arrow    = @glyphs[:arrow]
      def dash     = @glyphs[:dash]

      def header
        [
          rule("="),
          center("RECONCILIATION REPORT"),
          center("recon-engine v#{ReconEngine::VERSION}  #{sep}  #{report.started_at.strftime("%F %T %Z")}"),
          rule("=")
        ].join("\n")
      end

      def sources_section
        lines = ["INPUTS"]
        report.inputs.each { |input| lines.concat(input_lines(input)) }
        lines << ""
        lines << profile_line("ledger   ", report.ledger_profile)
        lines << profile_line("warehouse", report.warehouse_profile)
        lines.join("\n")
      end

      def input_lines(input)
        ["  #{input[:role].to_s.ljust(10)} #{input[:path]}",
         "  #{" ".ljust(10)} #{input[:rows]} rows #{sep} #{input[:digest][0, 12]}#{ellipsis}"]
      end

      def profile_line(label, profile)
        "  #{label} #{profile.row_count} rows, #{Money.humanize(profile.total_cents)}, " \
          "#{profile.accounts.size} accounts"
      end

      def matching_section
        result = report.match_result
        lines = ["", "MATCHING"]
        lines << "  matched sets      #{result.matches.length} " \
                 "(#{format("%.2f", result.match_rate * 100)}% of ledger rows)"
        result.strategy_counts.each do |strategy, count|
          lines << "    #{strategy.to_s.ljust(16)}#{count}"
        end
        lines << "  unmatched ledger    #{result.unmatched_ledger.length}"
        lines << "  unmatched warehouse #{result.unmatched_warehouse.length}"
        lines.join("\n")
      end

      def summary_section
        lines = ["", rule("-"), "SUMMARY", rule("-")]

        if report.clean?
          lines << colorize("  CLEAN #{dash} the two sources agree under the configured tolerances.", :green)
          return lines.join("\n")
        end

        lines << "  #{colorize(report.break_count.to_s, :red)} breaks in #{report.clusters.length} clusters"
        lines << "  row-level impact  #{colorize(Money.humanize(report.row_level_impact_cents), :yellow)}"
        lines << ""
        lines.concat(break_type_lines)
        lines.concat(classification_lines) if report.agent_ran?
        lines.join("\n")
      end

      def break_type_lines
        report.breaks_by_type.map do |type, count|
          "    #{count.to_s.rjust(6)}  #{Breaks::BreakRecord::TYPES.fetch(type.to_sym)[:label]}"
        end
      end

      def classification_lines
        rows = report.classification_summary.map do |classification, stats|
          "    #{classification.ljust(22)}#{stats[:clusters].to_s.rjust(3)} clusters #{sep} " \
            "#{stats[:breaks].to_s.rjust(6)} breaks #{sep} #{Money.humanize(stats[:magnitude_cents])}"
        end
        ["", "  BY CLASSIFICATION", *rows]
      end

      def clusters_section
        return nil if report.clusters.empty?

        lines = ["", rule("-"), "FINDINGS", rule("-")]
        report.clusters.each_with_index do |cluster, index|
          lines.concat(cluster_block(cluster, index + 1))
        end
        lines.join("\n")
      end

      def cluster_block(cluster, position)
        finding = report.finding_for(cluster)
        lines   = ["",
                   "#{position}. #{cluster.label} #{dash} #{cluster.count} break(s), " \
                   "#{Money.humanize(cluster.magnitude_cents)}",
                   colorize("   #{cluster.id} #{sep} #{signature_text(cluster)}", :grey)]
        if finding.nil?
          return lines << colorize("   not investigated (agent disabled or cluster budget reached)", :grey)
        end

        lines + finding_lines(finding)
      end

      def finding_lines(finding)
        ["   #{colorize(finding.classification, classification_color(finding))} " \
         "#{colorize("(confidence #{finding.confidence})", :grey)}",
         wrap(finding.explanation, "   "),
         *finding.evidence.first(3).map { |item| wrap("- #{item}", "     ") },
         wrap("#{arrow} #{finding.suggested_action}", "   "),
         colorize("   #{provenance_text(finding)}", :grey)]
      end

      def signature_text(cluster)
        cluster.signature.map { |k, v| "#{k}=#{Array(v).join("+")}" }.join(" ")
      end

      def provenance_text(finding)
        parts = ["#{finding.provider}/#{finding.model}"]
        parts << (finding.model_backed ? "model-backed" : "scripted stand-in, not a model")
        parts << "#{finding.tool_calls} tool calls"
        parts << "#{finding.repairs} schema repairs" if finding.repairs.positive?
        parts << "DEGRADED" if finding.degraded
        parts.join(" #{sep} ")
      end

      def classification_color(finding)
        return :grey if finding.degraded

        case finding.classification
        when "TIMING_DIFFERENCE", "ROUNDING" then :blue
        when "GENUINE_DISCREPANCY", "MISSING_IN_TARGET" then :red
        when "UNKNOWN" then :grey
        else :yellow
        end
      end

      def footer
        [
          "",
          rule("="),
          "  fingerprint  #{report.deterministic_fingerprint[0, 32]}#{ellipsis}",
          "  duration     #{format("%.3f", report.duration_seconds)}s",
          agent_footer,
          rule("=")
        ].compact.join("\n")
      end

      def agent_footer
        return "  agent        disabled" unless report.config.agent_enabled

        backing = report.model_backed_agent? ? "model-backed" : "scripted stand-in (no model called)"
        line = "  agent        #{report.config.agent_provider} #{sep} #{backing} #{sep} " \
               "#{report.findings.length} clusters investigated"
        usage = report.agent_usage
        return line unless usage.calls.positive?

        "#{line}\n#{usage_footer(usage)}"
      end

      def usage_footer(usage)
        waited = usage.wait_ms.positive? ? " #{sep} #{seconds(usage.wait_ms)} waiting on rate limits" : ""
        "  model usage  #{usage.calls} calls #{sep} #{group(usage.total_tokens)} tokens " \
          "(#{group(usage.thinking_tokens)} thinking) #{sep} #{seconds(usage.latency_ms)} in the model#{waited}"
      end

      def seconds(milliseconds) = format("%.1fs", milliseconds / 1000.0)
      def group(number)         = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

      # --- formatting helpers ------------------------------------------------

      def rule(char) = char * WIDTH

      def center(text)
        padding = [(WIDTH - text.length) / 2, 0].max
        (" " * padding) + text
      end

      def wrap(text, indent, width: WIDTH)
        limit = width - indent.length
        words = text.to_s.split(/\s+/)
        lines = words.each_with_object([[]]) do |word, acc|
          if (acc.last + [word]).join(" ").length > limit && !acc.last.empty?
            acc << [word]
          else
            acc.last << word
          end
        end
        lines.map { |line| indent + line.join(" ") }.join("\n")
      end

      def asciify(text)
        swapped = text.gsub(Regexp.union(TRANSLITERATIONS.keys), TRANSLITERATIONS)
        swapped.encode("US-ASCII", invalid: :replace, undef: :replace, replace: "?")
               .encode(text.encoding)
      end

      def colorize(text, color)
        return text unless @color && COLORS.key?(color)

        "\e[#{COLORS[color]}m#{text}\e[0m"
      end
    end
  end
end
