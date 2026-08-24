# frozen_string_literal: true

module ReconEngine
  module Breaks
    module Clusterer
      module_function

      def call(breaks)
        breaks
          .group_by { |record| [record.type, record.signature] }
          .map { |(type, signature), members| Cluster.build(type: type, signature: signature, breaks: members) }
          .sort_by(&method(:rank))
      end

      # Row-level before aggregate, then money, then volume, then id.
      #
      # Row-level first because a control total that does not tie is a
      # consequence of rows that are wrong, and leading with the consequence
      # buries the cause. Volume before id because an entire feed arriving a day
      # late is thousands of zero-dollar breaks and still the most important
      # thing in the report. Id last makes the order total.
      def rank(cluster)
        [cluster.row_level? ? 0 : 1, -cluster.magnitude_cents.abs, -cluster.count, cluster.id]
      end
    end
  end
end
