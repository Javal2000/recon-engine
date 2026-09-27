# frozen_string_literal: true

module ReconEngine
  module Breaks
    # A group of breaks that look like the same underlying problem.
    #
    # Causes are rare and symptoms are numerous: one skipped partition upstream
    # is one cause and fifty thousand missing-row breaks. Clustering is also what
    # makes the agent affordable, since the LLM runs once per cluster.
    class Cluster < Data.define(:id, :type, :signature, :break_ids, :count,
                                :magnitude_cents, :partitions, :samples, :attribution)
      MAX_SAMPLES = 3

      # Only aggregate clusters carry an attribution (see Breaks::Attribution).
      def initialize(attribution: nil, **fields) = super

      def self.build(type:, signature:, breaks:)
        ordered = breaks.sort_by(&:id)
        id = "cls_#{Digest::SHA256.hexdigest(JSON.generate([type, signature]))[0, 10]}"
        new(
          id: id,
          type: type,
          signature: signature,
          break_ids: ordered.map(&:id),
          count: ordered.length,
          magnitude_cents: ordered.sum(&:magnitude_cents),
          partitions: ordered.map { |b| b.partition[:date] }.compact.uniq.sort,
          samples: ordered.first(MAX_SAMPLES)
        )
      end

      def label = BreakRecord::TYPES.fetch(type)[:label]
      def row_level? = BreakRecord::TYPES.fetch(type)[:level] == :row

      def to_report_h
        {
          id: id,
          type: type.to_s,
          label: label,
          signature: signature,
          break_count: count,
          magnitude: Money.format(magnitude_cents),
          magnitude_cents: magnitude_cents,
          partitions: partitions,
          sample_breaks: samples.map(&:to_report_h),
          attribution: attribution&.to_report_h
        }.compact
      end

      def explained? = attribution&.explained? || false
    end
  end
end
