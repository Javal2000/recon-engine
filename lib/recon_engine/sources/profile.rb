# frozen_string_literal: true

module ReconEngine
  module Sources
    # Aggregate facts about one source, accumulated in a single streaming pass.
    #
    # Control totals, row counts and duplicate detection only need counters, so
    # they cost memory proportional to distinct keys rather than rows.
    class Profile
      attr_reader :name, :row_count, :totals_by_partition, :rows_by_partition,
                  :key_rows, :accounts, :statuses, :min_date, :max_date, :schema

      def self.build(source)
        new(source.name, schema: source.schema).tap do |profile|
          source.each { |txn| profile.observe(txn) }
          profile.freeze!
        end
      end

      def initialize(name, schema: {})
        @name                = name
        @schema              = schema
        @row_count           = 0
        @totals_by_partition = Hash.new(0)           # [date, currency] => cents
        @rows_by_partition   = Hash.new(0)           # [date, currency] => count
        @key_rows            = Hash.new { |h, k| h[k] = [] } # business_key => [row numbers]
        @accounts            = Set.new
        @statuses            = Hash.new(0)
      end

      def observe(txn)
        @row_count += 1
        partition = [txn.posted_date, txn.currency]
        @totals_by_partition[partition] += txn.amount_cents
        @rows_by_partition[partition]   += 1
        @key_rows[txn.business_key] << txn.row_number
        @accounts << txn.account_id
        @statuses[txn.status] += 1
        @min_date = txn.posted_date if @min_date.nil? || txn.posted_date < @min_date
        @max_date = txn.posted_date if @max_date.nil? || txn.posted_date > @max_date
        self
      end

      def freeze!
        @totals_by_partition.freeze
        @rows_by_partition.freeze
        @key_rows.freeze
        freeze
      end

      def total_cents
        @totals_by_partition.values.sum
      end

      def partitions
        @totals_by_partition.keys
      end

      # business_key => row numbers, for keys that appear more than once.
      def duplicate_keys
        @key_rows.select { |_key, rows| rows.length > 1 }
      end

      def to_report_h
        {
          source: name.to_s,
          row_count: row_count,
          total_amount: Money.format(total_cents),
          distinct_accounts: accounts.size,
          date_range: [min_date&.iso8601, max_date&.iso8601],
          statuses: statuses.sort.to_h
        }
      end
    end
  end
end
