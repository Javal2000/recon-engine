# frozen_string_literal: true

module ReconEngine
  module Reporting
    # The HISTORY section of the terminal report, shown when the run was
    # recorded with --db. Mixed into CliReport and uses its helpers.
    module CliHistory
      private

      def history_section
        history = report.history
        return nil unless history

        lines = ["", rule("-"), "HISTORY", rule("-")]
        if history.first_run?
          lines << wrap("run #{history.run.number} in #{history.database}, the first one there. " \
                        "Every break starts ageing from here.", "  ")
          return lines.join("\n")
        end

        lines.concat(history_notes(history))
        lines.concat(history_table(history))
        lines.concat(history.schema_changes.map { |change| "  schema changed  #{change.describe}" })
        lines.join("\n")
      end

      def history_notes(history)
        previous = history.previous
        notes = [wrap("run #{history.run.number} in #{history.database}, compared with run #{previous.number} " \
                      "(#{Time.iso8601(previous.started_at).strftime("%F %H:%M %Z")})", "  ")]
        if history.rerun?
          notes << colorize("  same inputs, settings and breaks as run #{history.run.number}, " \
                            "so it was not recorded again", :grey)
        end
        if history.settings_changed?
          notes << colorize("  the settings changed since run #{previous.number}, so some of the " \
                            "difference may come from them", :yellow)
        end
        notes << ""
      end

      def history_table(history)
        oldest = history.oldest
        rows = [
          ["new", history.opened, :red, nil],
          ["still open", history.still_open, :yellow,
           oldest && "oldest open since run #{oldest.first_seen_run} (#{oldest.first_seen_at[0, 10]})"],
          ["resolved", history.resolved, :green, nil]
        ]
        lines = rows.map do |label, entries, color, note|
          "  #{colorize(label.ljust(12), color)}#{entries.length.to_s.rjust(6)} breaks  " \
            "#{Money.humanize(history.row_level_cents(entries)).rjust(14)}#{"  #{note}" if note}"
        end
        lines << wrap(history.resolved_text, " " * 14) unless history.resolved.empty?
        lines
      end
    end
  end
end
