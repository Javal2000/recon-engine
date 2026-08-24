# frozen_string_literal: true

module ReconEngine
  module Breaks
    # One thing the deterministic layer found wrong: what disagrees, where, and
    # how much money is involved. It does not say why; that is the agent's job,
    # and keeping them apart is what lets this output be asserted on exactly.
    class BreakRecord < Data.define(:id, :type, :level, :partition, :magnitude_cents,
                                    :ledger_refs, :warehouse_refs, :details)
      # Only row-level magnitudes reach the headline impact. Otherwise a missing
      # row is counted twice: once as itself, once as the control total it moved.
      TYPES = {
        missing_in_target: { level: :row,       label: "Missing in warehouse" },
        orphan_in_target: { level: :row,       label: "Orphan in warehouse" },
        duplicate: { level: :row,       label: "Duplicate business key" },
        value_mismatch: { level: :row,       label: "Matched but values disagree" },
        control_total_mismatch: { level: :aggregate, label: "Control total does not tie" },
        row_count_mismatch: { level: :aggregate, label: "Row count does not tie" },
        # Aggregate, because it is a property of the dataset rather than of any
        # particular row. There are no refs to point at and no dollars to sum.
        schema_drift: { level: :aggregate, label: "Schema drift between sources" }
      }.freeze

      def self.build(type:, partition:, magnitude_cents: 0, ledger_refs: [], warehouse_refs: [], details: {})
        meta = TYPES.fetch(type) { raise ArgumentError, "unknown break type #{type.inspect}" }
        record = new(
          id: nil,
          type: type,
          level: meta[:level],
          partition: normalize_partition(partition),
          magnitude_cents: magnitude_cents,
          ledger_refs: ledger_refs.sort,
          warehouse_refs: warehouse_refs.sort,
          details: details.sort.to_h
        )
        record.with(id: record.compute_id)
      end

      def self.normalize_partition(partition)
        {
          date: partition[:date]&.to_s,
          account_id: partition[:account_id],
          currency: partition[:currency]
        }
      end

      # Content-addressed id: the same break in the same place with the same
      # magnitude always gets the same id, across machines and across runs. This
      # is what makes the run fingerprint stable and what lets a downstream
      # system dedupe breaks it has already seen.
      def compute_id
        payload = JSON.generate([type, partition, magnitude_cents, ledger_refs, warehouse_refs, details])
        "brk_#{Digest::SHA256.hexdigest(payload)[0, 12]}"
      end

      def label = TYPES.fetch(type)[:label]
      def row_level? = level == :row

      # The clustering key. Five thousand rows dropped by one upstream job share
      # a signature; five thousand unrelated breaks do not.
      def signature
        case type
        when :missing_in_target, :orphan_in_target
          { date: partition[:date], currency: partition[:currency] }
        when :value_mismatch
          { fields: details[:fields], band: details[:band] }
        when :duplicate
          { source: details[:source] }
        when :control_total_mismatch, :row_count_mismatch
          { currency: partition[:currency] }
        when :schema_drift
          # By kind, not by column: "three columns lost their decimals" is one
          # pipeline change and should read as one finding.
          { kind: details[:kind] }
        else
          { date: partition[:date] }
        end
      end

      def to_report_h
        {
          id: id,
          type: type.to_s,
          level: level.to_s,
          label: label,
          partition: partition,
          magnitude: Money.format(magnitude_cents),
          magnitude_cents: magnitude_cents,
          ledger_refs: ledger_refs,
          warehouse_refs: warehouse_refs,
          details: details
        }
      end
    end
  end
end
