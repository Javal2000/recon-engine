# frozen_string_literal: true

module ReconEngine
  module Breaks
    # Explains each control-total and row-count break from the row-level breaks
    # on the same day and in the same currency.
    #
    # A daily total that doesn't tie is almost never a separate problem: it is
    # the rows already reported, seen as a sum. Adding up each row-level break's
    # effect on its day (a missing row takes its amount away, an orphan adds it,
    # a late row moves it to the next day) reproduces every gap exactly, so the
    # engine explains aggregates itself rather than asking a model. Split
    # deposits that reconciled cleanly raise no break but still add rows, so
    # they are counted too.
    #
    # What is left over is something the row-level checks missed. That residual
    # is zero on every generated dataset, and it is the only part of an
    # aggregate cluster that goes to the agent.
    class Attribution
      ATTRIBUTABLE = { control_total_mismatch: :cents, row_count_mismatch: :rows }.freeze

      CAUSES = {
        "missing_in_target" => "missing in warehouse",
        "orphan_in_target" => "orphan in warehouse",
        "duplicate" => "extra duplicate copies",
        "value_mismatch:date_shifted" => "posted on a different day",
        "value_mismatch:sub_tolerance" => "rounding within tolerance",
        "value_mismatch:material" => "changed amounts",
        "split" => "split deposits, reconciled"
      }.freeze

      Component = Data.define(:cause, :breaks, :value) do
        def label = CAUSES.fetch(cause, cause)
      end

      # What explains one aggregate cluster. `unexplained` counts the breaks
      # whose own day and currency do not balance, so offsetting errors on two
      # different days cannot pass as an explanation.
      Summary = Data.define(:measure, :gap, :components, :residual, :unexplained) do
        def explained? = unexplained.zero?

        def to_report_h
          { measure: measure.to_s, explained: explained?, gap: shown(gap), residual: shown(residual),
            unexplained_breaks: unexplained,
            components: components.map do |c|
              { cause: c.cause, label: c.label, breaks: c.breaks, value: shown(c.value) }
            end }
        end

        def shown(value) = measure == :cents ? Money.format(value) : value
      end

      def initialize(breaks, context)
        @breaks  = breaks
        @context = context
      end

      # Returns the clusters with an attribution attached to every aggregate one.
      def annotate(clusters)
        clusters.map do |cluster|
          measure = ATTRIBUTABLE[cluster.type]
          measure ? cluster.with(attribution: summarize(cluster.break_ids, measure)) : cluster
        end
      end

      private

      def summarize(break_ids, measure)
        targets    = break_ids.map { |id| by_id.fetch(id) }
        components = components_for(targets, measure)
        gap        = targets.sum { |target| gap_of(target) }
        Summary.new(measure: measure, gap: gap, components: components, residual: gap - components.sum(&:value),
                    unexplained: targets.count { |target| !balances?(target, measure) })
      end

      # A late row takes money off one day and puts it on the next, so it can
      # net to zero across the cluster while being the reason both days are
      # off. A cause is listed if it moved anything on any day.
      def components_for(targets, measure)
        touched = cause_totals(targets, measure).select { |_cause, total| total[:touched] }
        touched.map { |cause, total| Component.new(cause: cause, **total.slice(:breaks, :value)) }
               .sort_by { |component| [-component.value.abs, component.cause] }
      end

      def cause_totals(targets, measure)
        totals = Hash.new { |hash, cause| hash[cause] = { ids: Set.new, value: 0, touched: false } }
        targets.flat_map { |target| effects[key_of(target)].to_a }.each do |cause, effect|
          totals[cause][:ids].merge(effect[:ids])
          totals[cause][:value] += effect[measure]
          totals[cause][:touched] ||= !effect[measure].zero?
        end
        totals.transform_values { |total| total.merge(breaks: total[:ids].size) }
      end

      def balances?(target, measure)
        gap_of(target) == effects[key_of(target)].sum { |_cause, effect| effect[measure] }
      end

      def gap_of(target)
        target.type == :control_total_mismatch ? target.magnitude_cents : target.details.fetch(:delta)
      end

      def key_of(target) = [target.partition[:date], target.partition[:currency]]

      def by_id = @by_id ||= @breaks.to_h { |record| [record.id, record] }

      # (date, currency) => cause => cents, rows and the ids that contributed.
      def effects
        @effects ||= begin
          table = Hash.new do |days, key|
            days[key] = Hash.new { |causes, cause| causes[cause] = { cents: 0, rows: 0, ids: [] } }
          end
          @breaks.select(&:row_level?).each { |record| add_break(table, record) }
          clean_splits.each { |match| add_rows(table, "split", "split:#{match.refs.join(",")}", match_rows(match)) }
          table
        end
      end

      def add_break(table, record)
        cause = record.type == :value_mismatch ? "value_mismatch:#{record.details[:band]}" : record.type.to_s
        return add_rows(table, cause, record.id, break_rows(record)) unless record.type == :duplicate

        # A duplicate names every copy, but only the surplus ones are extra.
        sign   = record.details[:source] == "warehouse" ? 1 : -1
        effect = table[key_of(record)][cause]
        effect[:cents] += sign * record.magnitude_cents
        effect[:rows]  += sign * (record.details[:occurrences] - 1)
        effect[:ids] << record.id
      end

      # Warehouse rows add to the gap and ledger rows take from it, each on its
      # own posting date.
      def add_rows(table, cause, id, signed_rows)
        signed_rows.each do |txn, sign|
          effect = table[[txn.posted_date.iso8601, txn.currency]][cause]
          effect[:cents] += sign * txn.amount_cents
          effect[:rows]  += sign
          effect[:ids] << id unless effect[:ids].include?(id)
        end
      end

      def break_rows(record)
        record.ledger_refs.map { |ref| [row_at(ref), -1] } + record.warehouse_refs.map { |ref| [row_at(ref), 1] }
      end

      def match_rows(match)
        match.ledger_rows.map { |txn| [txn, -1] } + match.warehouse_rows.map { |txn| [txn, 1] }
      end

      def row_at(ref)
        source, row_number = ref.split(":")
        @context.rows_for(source.to_sym).fetch(Integer(row_number))
      end

      # Splits covered by a value break are already counted through its refs.
      def clean_splits
        covered = @breaks.select { |record| record.type == :value_mismatch }.flat_map(&:warehouse_refs).to_set
        @context.match_result.matches.select do |match|
          match.strategy == :split && match.warehouse_rows.none? { |txn| covered.include?(txn.ref) }
        end
      end
    end
  end
end
