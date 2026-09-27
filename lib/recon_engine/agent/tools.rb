# frozen_string_literal: true

module ReconEngine
  module Agent
    # The only way the agent can learn anything about the data. There is no tool
    # that compares amounts, decides whether rows match, or writes anything.
    #
    # Bad arguments and unknown tool names return an `error` key instead of
    # raising, so the model can correct itself without losing the calls that
    # already succeeded.
    class Tools
      MAX_ROWS = 20

      SPECS = [
        {
          name: "fetch_rows",
          description: "Return raw rows from one source, filtered. Use it to see what the data actually looks like.",
          arguments: {
            source: "\"ledger\" or \"warehouse\" (required)",
            account_id: "optional account filter",
            date: "optional ISO-8601 posted date filter",
            txn_id: "optional transaction id filter",
            limit: "optional, max #{MAX_ROWS}"
          }
        },
        {
          name: "check_adjacent_periods",
          description: "Count rows in both sources on the days either side of a date, for one " \
                       "account/currency/amount. This is the primary test for whether a break is " \
                       "a settlement timing lag.",
          arguments: {
            account_id: "required",
            date: "required, ISO-8601",
            amount: "required, decimal string such as \"-120.50\"",
            currency: "optional, defaults to USD"
          }
        },
        {
          name: "get_schema",
          description: "Return the column names and inferred types of one source. " \
                       "Use it when a break looks structural.",
          arguments: { source: "\"ledger\" or \"warehouse\" (required)" }
        },
        {
          name: "summarize_cluster",
          description: "Aggregate a set of break ids: count, total magnitude, accounts and date range involved.",
          arguments: { break_ids: "required, array of break ids" }
        }
      ].freeze

      NAMES = SPECS.map { |spec| spec[:name] }.freeze

      def initialize(context:, breaks:)
        @context = context
        @config  = context.config
        @breaks  = breaks.to_h { |record| [record.id, record] }
        @calls   = 0
      end

      attr_reader :calls

      def call(name, arguments)
        @calls += 1
        args = (arguments || {}).transform_keys(&:to_s)

        case name
        when "fetch_rows"             then fetch_rows(args)
        when "check_adjacent_periods" then check_adjacent_periods(args)
        when "get_schema"             then get_schema(args)
        when "summarize_cluster"      then summarize_cluster(args)
        else { "error" => "unknown tool #{name.inspect}; available tools are #{NAMES.join(", ")}" }
        end
      rescue ArgumentError, TypeError => e
        { "error" => "#{name} failed: #{e.message}" }
      end

      def descriptor
        SPECS.map do |spec|
          "- #{spec[:name]}: #{spec[:description]}\n    arguments: " \
            "#{spec[:arguments].map { |k, v| "#{k}: #{v}" }.join("; ")}"
        end.join("\n")
      end

      private

      def fetch_rows(args)
        source = symbol_source(args["source"])
        return { "error" => "source must be \"ledger\" or \"warehouse\"" } if source.nil?

        limit = [(args["limit"] || 10).to_i, MAX_ROWS].min.clamp(1, MAX_ROWS)
        rows  = args["account_id"] ? by_account(source).fetch(args["account_id"], []) : @context.rows_of(source)
        rows  = rows.select { |t| t.posted_date.iso8601 == args["date"] } if args["date"]
        rows  = rows.select { |t| t.txn_id == args["txn_id"] } if args["txn_id"]

        {
          "source" => source.to_s,
          "matched_rows" => rows.length,
          "returned" => [rows.length, limit].min,
          "rows" => rows.sort_by(&:sort_key).first(limit).map { |t| t.to_report_h.transform_keys(&:to_s) }
        }
      end

      # The timing test: how many rows sit in each source on each day of the
      # window for this account, currency and amount? A row that moved from
      # Monday to Tuesday is a settlement lag; a row absent everywhere was dropped.
      def check_adjacent_periods(args)
        date     = Date.iso8601(args.fetch("date"))
        account  = args.fetch("account_id")
        currency = (args["currency"] || "USD").upcase
        cents    = args["amount"] ? Money.to_cents(args["amount"].to_s) : nil
        window   = @config.timing_window_days

        days = ((date - window)..(date + window)).to_a
        per_day = days.map do |day|
          {
            "date" => day.iso8601,
            "ledger_rows" => count_rows(:ledger, account, currency, day),
            "warehouse_rows" => count_rows(:warehouse, account, currency, day)
          }
        end

        adjacent = if cents.nil?
                     0
                   else
                     (days - [date]).sum do |day|
                       amount_matches(:ledger, account, currency, day, cents) +
                         amount_matches(:warehouse, account, currency, day, cents)
                     end
                   end

        {
          "account_id" => account,
          "currency" => currency,
          "target_date" => date.iso8601,
          "window_days" => window,
          "tolerance_cents" => @config.tolerance_cents,
          "per_day" => per_day,
          "candidate_matches_in_adjacent_period" => adjacent
        }
      end

      def get_schema(args)
        source = symbol_source(args["source"])
        return { "error" => "source must be \"ledger\" or \"warehouse\"" } if source.nil?

        profile = @context.profile_for(source)
        {
          "source" => source.to_s,
          "columns" => profile.schema,
          "row_count" => profile.row_count,
          "date_range" => [profile.min_date&.iso8601, profile.max_date&.iso8601]
        }
      end

      def summarize_cluster(args)
        ids = Array(args["break_ids"])
        return { "error" => "break_ids must be a non-empty array" } if ids.empty?

        found   = ids.filter_map { |id| @breaks[id] }
        missing = ids - found.map(&:id)
        return { "error" => "no such break ids: #{missing.join(", ")}" } if found.empty?

        {
          "requested" => ids.length,
          "resolved" => found.length,
          "unknown_ids" => missing,
          "types" => found.map { |b| b.type.to_s }.tally,
          "total_magnitude" => Money.format(found.sum(&:magnitude_cents)),
          "accounts" => found.filter_map { |b| b.partition[:account_id] }.uniq.sort.first(10),
          "dates" => found.filter_map { |b| b.partition[:date] }.uniq.sort,
          "sample_details" => found.first(3).map { |b| b.details.transform_keys(&:to_s) }
        }
      end

      # --- helpers -----------------------------------------------------------

      def symbol_source(value)
        case value.to_s
        when "ledger" then :ledger
        when "warehouse" then :warehouse
        end
      end

      def count_rows(source, account, currency, day)
        by_day(source).fetch([account, currency, day], []).length
      end

      def amount_matches(source, account, currency, day, cents)
        by_day(source).fetch([account, currency, day], []).count do |t|
          Money.within_tolerance?(t.amount_cents, cents, @config.tolerance_cents)
        end
      end

      # Built once per source on first use. Every timing lookup is keyed by
      # account, currency and day, so a call reads one small bucket instead of
      # scanning every row.
      def by_day(source)
        (@by_day ||= {})[source] ||= @context.rows_of(source).group_by { |t| [t.account_id, t.currency, t.posted_date] }
      end

      def by_account(source)
        (@by_account ||= {})[source] ||= @context.rows_of(source).group_by(&:account_id)
      end
    end
  end
end
