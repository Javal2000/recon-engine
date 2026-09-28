# frozen_string_literal: true

module ReconEngine
  module History
    # A run as the history database remembers it.
    RunInfo = Data.define(:number, :started_at, :fingerprint, :config_digest, :break_count,
                          :row_level_impact_cents)

    # One break's place in the history. first_seen_run is where its current
    # streak began: a break that is fixed and later comes back starts again.
    Entry = Data.define(:key, :break_id, :type, :row_level, :magnitude_cents, :first_seen_run, :first_seen_at) do
      def runs_open(through) = through - first_seen_run + 1

      def to_report_h(through)
        { key: key, break_id: break_id, type: type, magnitude_cents: magnitude_cents,
          first_seen_run: first_seen_run, first_seen_at: first_seen_at, runs_open: runs_open(through) }
      end
    end

    # A column that appeared, disappeared or changed type in one source since
    # the previous run. Checks::SchemaDrift compares the two sources with each
    # other; this compares each source with itself a run ago.
    SchemaChange = Data.define(:source, :kind, :column, :from, :to) do
      # Same rules as SchemaDrift: an empty schema was never inferred, and
      # "unknown" means the sample was blank, which is not a type.
      def self.between(source, was, now)
        return [] if was.empty? || now.empty?

        removed = (was.keys - now.keys).sort.map { |column| new(source, "column_removed", column, was[column], nil) }
        added   = (now.keys - was.keys).sort.map { |column| new(source, "column_added", column, nil, now[column]) }
        retyped = (was.keys & now.keys).sort.filter_map do |column|
          types = [was[column], now[column]]
          new(source, "type_changed", column, *types) unless types.uniq.one? || types.include?("unknown")
        end
        removed + added + retyped
      end

      def describe
        case kind
        when "column_added"   then "#{source}: column #{column.inspect} added (#{to})"
        when "column_removed" then "#{source}: column #{column.inspect} removed"
        else "#{source}: column #{column.inspect} changed from #{from} to #{to}"
        end
      end
    end

    # What this run looks like next to the one before it: which breaks are
    # new, which are still open and since when, and which went away.
    class Summary
      attr_reader :database, :run, :previous, :opened, :still_open, :resolved, :schema_changes

      def initialize(database:, run:, previous:, rerun:, opened:, still_open:, resolved:, schema_changes:)
        @database       = database
        @run            = run
        @previous       = previous
        @rerun          = rerun
        @opened         = opened
        @still_open     = still_open
        @resolved       = resolved
        @schema_changes = schema_changes
        @entries        = (opened + still_open).to_h { |entry| [entry.break_id, entry] }
      end

      # The inputs, settings and breaks are identical to the latest recorded
      # run, so it was not recorded a second time.
      def rerun? = @rerun

      def first_run? = previous.nil?

      # Tolerance or timing window changed, so part of the difference may come
      # from the settings rather than the data.
      def settings_changed? = !first_run? && previous.config_digest != run.config_digest

      def entry_for(break_id) = @entries[break_id]

      def oldest = still_open.min_by { |entry| [entry.first_seen_run, entry.key] }

      # Money as the report counts it: row-level breaks only, since a control
      # total describes the same dollars as the rows behind it.
      def row_level_cents(entries) = entries.select(&:row_level).sum { |entry| entry.magnitude_cents.abs }

      def resolved_by_type
        resolved.map(&:type).tally.sort_by { |type, count| [-count, type] }.to_h
      end

      # How long a cluster's breaks have been around, or nil on a first run,
      # where everything is new and saying so on every cluster is noise.
      def cluster_age(cluster)
        return nil if first_run?

        entries = cluster.break_ids.filter_map { |id| entry_for(id) }
        carried = entries.reject { |entry| entry.first_seen_run == run.number }
        { new: entries.length - carried.length, carried: carried.length,
          since: carried.map(&:first_seen_run).min }
      end

      # "new this run", "open since run 3 (4 runs)", or both when a cluster
      # holds old and new breaks.
      def age_text(cluster)
        age = cluster_age(cluster)
        return nil if age.nil? || (age[:new] + age[:carried]).zero?
        return "new this run" if age[:carried].zero?

        since = "open since run #{age[:since]} (#{run.number - age[:since] + 1} runs)"
        age[:new].zero? ? since : "#{age[:carried]} #{since}, #{age[:new]} new this run"
      end

      def resolved_text
        resolved_by_type.map { |type, count| "#{count} #{Breaks::BreakRecord::TYPES.fetch(type.to_sym)[:label]}" }
                        .join(", ")
      end

      def to_report_h
        {
          database: database,
          run_number: run.number,
          previous_run: previous && { run_number: previous.number, started_at: previous.started_at,
                                      deterministic_fingerprint: previous.fingerprint },
          rerun: rerun?,
          settings_changed: settings_changed?,
          new: section(opened, run.number),
          still_open: section(still_open, run.number),
          resolved: section(resolved, previous&.number),
          schema_changes: schema_changes.map(&:to_h)
        }
      end

      private

      def section(entries, through)
        cents = row_level_cents(entries)
        { count: entries.length, row_level_impact: Money.format(cents), row_level_impact_cents: cents,
          breaks: entries.map { |entry| entry.to_report_h(through) } }
      end
    end
  end
end
