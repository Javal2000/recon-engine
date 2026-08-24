# frozen_string_literal: true

module ReconEngine
  module Matching
    # Decides which ledger rows correspond to which warehouse rows.
    #
    # Three passes, strictly ordered from most to least confident. A row consumed
    # by an earlier pass is never reconsidered by a later one, which is what
    # makes the result independent of input order and therefore reproducible.
    #
    #   1. exact_key: same transaction id on both sides
    #   2. composite: same account + currency + amount + date, allowing an
    #      amount tolerance and a settlement timing window
    #   3. split: one row on one side against N rows on the other
    #
    # No model is involved anywhere in matching.
    class Engine
      def initialize(config)
        @config = config
      end

      # `ledger` and `warehouse` are any Enumerable of Transaction: a CsvSource,
      # an Array in a spec, or a future DatabaseSource. Nothing here knows the
      # difference.
      def call(ledger:, warehouse:)
        ledger_rows    = ledger.to_a.sort_by(&:sort_key)
        warehouse_rows = warehouse.to_a.sort_by(&:sort_key)

        matches = []
        remaining_a, remaining_b = match_exact_keys(ledger_rows, warehouse_rows, matches)
        remaining_a, remaining_b = match_composites(remaining_a, remaining_b, matches)
        remaining_a, remaining_b = match_splits(remaining_a, remaining_b, matches)

        Result.new(
          matches: matches.sort_by(&:sort_key),
          unmatched_ledger: remaining_a.sort_by(&:sort_key),
          unmatched_warehouse: remaining_b.sort_by(&:sort_key),
          ledger_count: ledger_rows.length,
          warehouse_count: warehouse_rows.length
        )
      end

      private

      # --- Pass 1: exact transaction id ------------------------------------

      def match_exact_keys(ledger_rows, warehouse_rows, matches)
        index = index_by(ledger_rows.select(&:keyed?), &:txn_id)

        leftover_b = warehouse_rows.reject do |b|
          next false unless b.keyed?

          bucket = index[b.txn_id]
          next false if bucket.nil? || bucket.empty?

          # `shift` consumes the candidate, so a duplicated id downstream matches
          # at most as many times as it appears upstream. The surplus falls
          # through to become an orphan, and Checks::Duplicates reports the
          # repetition separately.
          matches << MatchSet.exact(bucket.shift, b)
          true
        end

        consumed = matched_ledger_refs(matches)
        [ledger_rows.reject { |a| consumed.include?(a.ref) }, leftover_b]
      end

      # --- Pass 2: composite key with tolerance and timing window -----------

      def match_composites(ledger_rows, warehouse_rows, matches)
        index = index_by(ledger_rows, &:composite_key)
        consumed_a = Set.new

        leftover_b = warehouse_rows.reject do |b|
          candidate = probe_composite(index, b)
          next false if candidate.nil?

          consumed_a << candidate.ref
          matches << MatchSet.composite(candidate, b)
          true
        end

        [ledger_rows.reject { |a| consumed_a.include?(a.ref) }, leftover_b]
      end

      # Probe the ledger index outward from the warehouse row's own key: exact
      # first, then one day out, then one cent out, and so on. Closest wins, and
      # because the offsets are generated in a fixed order the choice between two
      # equally-close candidates is deterministic rather than incidental.
      def probe_composite(index, row)
        date_offsets.each do |days|
          cent_offsets.each do |cents|
            key    = [row.account_id, row.currency, row.amount_cents + cents, row.posted_date + days]
            bucket = index[key]
            next if bucket.nil? || bucket.empty?

            return bucket.shift
          end
        end
        nil
      end

      def date_offsets
        @date_offsets ||= [0] + (1..@config.timing_window_days).flat_map { |d| [d, -d] }
      end

      def cent_offsets
        @cent_offsets ||= [0] + (1..@config.tolerance_cents).flat_map { |c| [c, -c] }
      end

      # --- Pass 3: N-to-one --------------------------------------------------

      # One deposit upstream can arrive downstream as several lines, and the
      # reverse happens too (a warehouse rollup of several ledger entries). Both
      # directions run through the same subset search; only the roles swap.
      def match_splits(ledger_rows, warehouse_rows, matches)
        remaining_a, remaining_b = search_splits(ledger_rows, warehouse_rows, matches, one_side: :ledger)
        remaining_b, remaining_a = search_splits(remaining_b, remaining_a, matches, one_side: :warehouse)
        [remaining_a, remaining_b]
      end

      def search_splits(one_rows, many_rows, matches, one_side:)
        available = many_rows.dup
        consumed  = Set.new

        leftover_one = one_rows.reject do |one|
          candidates = split_candidates(one, available, consumed)
          subset     = find_subset(one.amount_cents, candidates)
          next false if subset.nil?

          subset.each { |row| consumed << row.ref }
          matches << if one_side == :ledger
                       MatchSet.split([one], subset)
                     else
                       MatchSet.split(subset, [one])
                     end
          true
        end

        [leftover_one, available.reject { |row| consumed.include?(row.ref) }]
      end

      # Bounded on purpose, since subset-sum is exponential. With 12 candidates
      # and at most 5 legs the search visits at most 1,585 subsets per unmatched
      # row, and the failure mode is "no split found" rather than a hung run.
      def split_candidates(one, available, consumed)
        window = @config.timing_window_days
        available
          .reject { |row| consumed.include?(row.ref) }
          .select do |row|
            row.account_id == one.account_id &&
              row.currency == one.currency &&
              (row.posted_date - one.posted_date).abs <= window &&
              same_sign?(row.amount_cents, one.amount_cents) &&
              row.amount_cents.abs <= one.amount_cents.abs + @config.tolerance_cents
          end
          .sort_by { |row| [-row.amount_cents.abs, row.sort_key] }
          .first(@config.max_split_candidates)
      end

      # Depth-first subset search with a magnitude prune. Returns the first
      # subset of size >= 2 that sums to the target within tolerance, or nil.
      def find_subset(target, candidates)
        return nil if candidates.length < 2

        tolerance = @config.tolerance_cents
        max_legs  = @config.max_split_legs
        found     = nil
        chosen    = []

        walk = lambda do |start, sum|
          return unless found.nil?

          if chosen.length >= 2 && (sum - target).abs <= tolerance
            found = chosen.dup
            return
          end
          return if chosen.length >= max_legs

          (start...candidates.length).each do |i|
            row      = candidates[i]
            next_sum = sum + row.amount_cents
            # Prune anything that has already overshot in the target's direction.
            next if target.positive? && next_sum > target + tolerance
            next if target.negative? && next_sum < target - tolerance

            chosen.push(row)
            walk.call(i + 1, next_sum)
            chosen.pop
            break unless found.nil?
          end
        end

        walk.call(0, 0)
        found
      end

      # --- helpers -----------------------------------------------------------

      def same_sign?(left, right)
        (left.negative? && right.negative?) || (left >= 0 && right >= 0)
      end

      def index_by(rows)
        rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, index|
          index[yield(row)] << row
        end
      end

      def matched_ledger_refs(matches)
        matches.flat_map { |m| m.ledger_rows.map(&:ref) }.to_set
      end
    end
  end
end
