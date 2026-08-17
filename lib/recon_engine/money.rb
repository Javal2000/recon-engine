# frozen_string_literal: true

module ReconEngine
  # Amounts are Integer cents everywhere. This engine's whole job is deciding
  # whether two numbers are equal, and `0.1 + 0.2 == 0.3` is false, so there is
  # no Float anywhere in the matching or checking path.
  module Money
    module_function

    # Parse a decimal string ("-1234.56") into cents.
    #
    # BigDecimal#round with no mode is half-up, matching the rounding the
    # upstream systems apply. Anything beyond 2 decimal places is rounded.
    def to_cents(value)
      case value
      when Integer    then value * 100
      when BigDecimal then (value * 100).round.to_i
      when String
        raise InputError, "amount is blank" if value.strip.empty?

        normalized = value.strip.delete(",").sub(/\A\+/, "")
        raise InputError, "amount #{value.inspect} is not a decimal number" unless normalized.match?(/\A-?\d+(\.\d+)?\z/)

        (BigDecimal(normalized) * 100).round.to_i
      when nil then raise InputError, "amount is missing"
      else
        raise InputError, "amount #{value.inspect} has unsupported type #{value.class}"
      end
    end

    # Canonical "-1234.56" form, used in CSV output and reports.
    def format(cents)
      sign  = cents.negative? ? "-" : ""
      whole = cents.abs / 100
      frac  = cents.abs % 100
      "#{sign}#{whole}.#{Kernel.format('%02d', frac)}"
    end

    def humanize(cents)
      sign  = cents.negative? ? "-" : ""
      whole = (cents.abs / 100).to_s.reverse.scan(/\d{1,3}/).join(",").reverse
      frac  = Kernel.format("%02d", cents.abs % 100)
      "#{sign}$#{whole}.#{frac}"
    end

    def within_tolerance?(left, right, tolerance_cents)
      (left - right).abs <= tolerance_cents
    end
  end
end
