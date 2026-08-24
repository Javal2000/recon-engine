# frozen_string_literal: true

module ReconEngine
  module Checks
    # Everything a check is allowed to look at. Passing one context object rather
    # than six positional arguments means adding a new input later does not force
    # every existing check to change its signature.
    class Context
      attr_reader :config, :match_result, :ledger_profile, :warehouse_profile,
                  :ledger_rows, :warehouse_rows

      def initialize(config:, match_result:, ledger_profile:, warehouse_profile:,
                     ledger_rows:, warehouse_rows:)
        @config            = config
        @match_result      = match_result
        @ledger_profile    = ledger_profile
        @warehouse_profile = warehouse_profile
        @ledger_rows       = ledger_rows
        @warehouse_rows    = warehouse_rows
        @indexes           = {}
      end

      # row_number => Transaction, built once per source and reused by every
      # check that needs to resolve a row reference back to a row.
      def rows_for(source)
        @indexes[source] ||= rows_of(source).to_h { |txn| [txn.row_number, txn] }
      end

      def rows_of(source)
        source == :ledger ? ledger_rows : warehouse_rows
      end

      def profile_for(source)
        source == :ledger ? ledger_profile : warehouse_profile
      end
    end

    # Base class for deterministic checks.
    class Base
      def self.inherited(subclass)
        super
        registry << subclass
      end

      def self.registry
        @registry ||= []
      end

      # Deterministic order, so breaks are produced in the same sequence every
      # run regardless of file load order.
      def self.all
        registry.sort_by(&:name)
      end

      def initialize(config)
        @config = config
      end

      # @return [Array<Breaks::BreakRecord>]
      def call(_context)
        raise NotImplementedError, "#{self.class}#call"
      end

      private

      attr_reader :config
    end
  end
end
