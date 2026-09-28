# frozen_string_literal: true

module ReconEngine
  module History
    # A name for each break that survives the files changing shape.
    #
    # Break ids hash the rows they point at, and rows are pointed at by line
    # number, so the same missing transaction gets a new id as soon as
    # tomorrow's file has its rows in a different order. History needs to know
    # it is the same problem, so it names a break by what it is about: the
    # business key of the rows involved (the transaction id, or account,
    # currency, amount and date when there is no id), and for daily totals the
    # day and currency.
    module Identity
      module_function

      # break id => stable key
      def keys_for(breaks, context)
        named = breaks.map { |record| [record, key_for(record, context)] }
        # Two breaks only share a key when a file holds two identical rows
        # without ids. Numbering them keeps both.
        named.group_by(&:last).flat_map do |key, group|
          group.sort_by { |record, _| record.id }.each_with_index.map do |(record, _), index|
            [record.id, index.zero? ? key : "#{key}##{index + 1}"]
          end
        end.to_h
      end

      def key_for(record, context)
        [record.type.to_s, *subject_of(record, context)].join("|")
      end

      # A value mismatch is keyed by its transaction alone, not by how the
      # values differ: a pair whose status gets fixed while its amount is still
      # wrong is the same open problem, not a resolved one and a new one.
      def subject_of(record, context)
        case record.type
        when :control_total_mismatch, :row_count_mismatch then record.partition.values.compact
        when :schema_drift then [record.details[:kind], record.details[:column]]
        when :duplicate    then [record.details[:source], record.details[:business_key]]
        else row_keys(record, context)
        end
      end

      # The ledger is the system of record, so its rows name the problem when
      # there are any. An orphan only has warehouse rows.
      def row_keys(record, context)
        refs = record.ledger_refs.empty? ? record.warehouse_refs : record.ledger_refs
        refs.map do |ref|
          source, row_number = ref.split(":")
          context.rows_for(source.to_sym).fetch(Integer(row_number)).business_key.join(":")
        end.sort
      end
    end
  end
end
