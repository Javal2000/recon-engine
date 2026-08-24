# frozen_string_literal: true

module ReconEngine
  module Sources
    # A CSV-backed transaction source.
    #
    # The public surface is deliberately small (`#each`, `#headers`, `#digest`)
    # so a future DatabaseSource can be dropped in without any caller changing.
    # Nothing downstream knows it is reading a file.
    class CsvSource
      include Enumerable

      REQUIRED_HEADERS = %w[txn_id account_id posted_date amount currency status].freeze

      # Rows sampled when inferring column types: enough that one odd row can't
      # decide a column, cheap on a file of any size.
      SCHEMA_SAMPLE_ROWS = 50

      attr_reader :path, :name

      def initialize(path, name:)
        @path = path.to_s
        @name = name.to_sym
        raise InputError, "#{@path} does not exist" unless File.file?(@path)
      end

      # Streams one row at a time, so memory stays flat regardless of file size.
      def each
        return enum_for(:each) unless block_given?

        validate_headers!
        row_number = 0
        CSV.foreach(@path, headers: true) do |row|
          row_number += 1
          yield parse_row(row, row_number)
        end
        self
      end

      def headers
        @headers ||= CSV.open(@path, "r", &:readline).map { |h| h.to_s.strip }
      end

      # Column names and types, inferred from a sample rather than the first row:
      # a column whose first value is "100" is not an integer column if a later
      # row holds "100.50".
      def schema
        @schema ||= begin
          samples = schema_sample
          headers.to_h { |header| [header, infer_column_type(samples[header])] }
        end
      end

      # Content hash of the input file. Part of the run fingerprint, so a run is
      # reproducible only against the exact bytes it was computed from.
      def digest
        @digest ||= Digest::SHA256.file(@path).hexdigest
      end

      def byte_size = File.size(@path)

      private

      def validate_headers!
        return if @validated

        missing = REQUIRED_HEADERS - headers
        unless missing.empty?
          raise InputError, "#{@path} is missing required column(s): #{missing.join(', ')}"
        end

        @validated = true
      end

      def parse_row(row, row_number)
        Transaction.new(
          source: @name,
          row_number: row_number,
          txn_id: normalize(row["txn_id"]),
          account_id: normalize(row["account_id"]) || raise_missing("account_id", row_number),
          posted_date: parse_date(row["posted_date"], row_number),
          amount_cents: parse_amount(row["amount"], row_number),
          currency: (normalize(row["currency"]) || "USD").upcase,
          status: (normalize(row["status"]) || "UNKNOWN").upcase
        )
      end

      def normalize(value)
        stripped = value&.strip
        stripped.nil? || stripped.empty? ? nil : stripped
      end

      def parse_date(value, row_number)
        text = normalize(value)
        raise_missing("posted_date", row_number) if text.nil?

        Date.iso8601(text)
      rescue Date::Error
        raise InputError, "#{@path} row #{row_number}: posted_date #{value.inspect} is not an ISO-8601 date"
      end

      def parse_amount(value, row_number)
        Money.to_cents(normalize(value))
      rescue InputError => e
        raise InputError, "#{@path} row #{row_number}: #{e.message}"
      end

      def raise_missing(column, row_number)
        raise InputError, "#{@path} row #{row_number}: #{column} is required but blank"
      end

      def schema_sample
        rows = CSV.foreach(@path, headers: true).first(SCHEMA_SAMPLE_ROWS)
        headers.to_h { |header| [header, rows.map { |row| row[header] }] }
      end

      # Integers and decimals together widen to decimal. Any other mix is
      # reported as string rather than guessed.
      def infer_column_type(values)
        types = values.map { |value| infer_type(value) }.reject { |type| type == "unknown" }.uniq
        return "unknown" if types.empty?
        return types.first if types.one?
        return "decimal"   if types.sort == %w[decimal integer]

        "string"
      end

      def infer_type(value)
        text = normalize(value)
        return "unknown" if text.nil?
        return "date"    if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        return "decimal" if text.match?(/\A-?\d+\.\d+\z/)
        return "integer" if text.match?(/\A-?\d+\z/)

        "string"
      end
    end
  end
end
