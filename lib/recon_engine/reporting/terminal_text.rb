# frozen_string_literal: true

module ReconEngine
  module Reporting
    # Plain-text layout for a terminal: a fixed width, optional colour, and an
    # ASCII fallback for consoles that can't render Unicode. Kept apart from
    # CliReport, which decides what the report says rather than how it looks.
    module TerminalText
      WIDTH = 78

      # ANSI colour, suppressed when stdout is not a TTY so that piping to a file
      # or capturing in CI does not fill the output with escape codes.
      COLORS = { red: 31, green: 32, yellow: 33, blue: 34, grey: 90 }.freeze

      # Unicode glyphs when the terminal can render them, ASCII otherwise. A
      # Windows console on the legacy code page turns "·" into mojibake.
      GLYPHS = {
        unicode: { sep: "·", ellipsis: "…", arrow: "→", dash: "—" },
        ascii: { sep: "|", ellipsis: "...", arrow: "->", dash: "--" }
      }.freeze

      # Agent explanations are free text written by a model, and models emit
      # em-dashes and curly quotes freely. Transliterating at the very end
      # catches whatever the provider decided to send.
      TRANSLITERATIONS = {
        "—" => "--", "–" => "-", "·" => "|", "…" => "...", "→" => "->",
        "“" => '"', "”" => '"', "‘" => "'", "’" => "'", "•" => "*", " " => " "
      }.freeze

      def self.unicode_terminal?
        encoding = $stdout.external_encoding || Encoding.default_external
        encoding.to_s.match?(/UTF-8/i)
      rescue StandardError
        false
      end

      private

      def sep      = @glyphs[:sep]
      def ellipsis = @glyphs[:ellipsis]
      def arrow    = @glyphs[:arrow]
      def dash     = @glyphs[:dash]

      def seconds(milliseconds) = format("%.1fs", milliseconds / 1000.0)
      def group(number)         = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

      def rule(char) = char * WIDTH

      def center(text)
        padding = [(WIDTH - text.length) / 2, 0].max
        (" " * padding) + text
      end

      def wrap(text, indent, width: WIDTH)
        limit = width - indent.length
        words = text.to_s.split(/\s+/)
        lines = words.each_with_object([[]]) do |word, acc|
          if (acc.last + [word]).join(" ").length > limit && !acc.last.empty?
            acc << [word]
          else
            acc.last << word
          end
        end
        lines.map { |line| indent + line.join(" ") }.join("\n")
      end

      def asciify(text)
        swapped = text.gsub(Regexp.union(TRANSLITERATIONS.keys), TRANSLITERATIONS)
        swapped.encode("US-ASCII", invalid: :replace, undef: :replace, replace: "?")
               .encode(text.encoding)
      end

      def colorize(text, color)
        return text unless @color && COLORS.key?(color)

        "\e[#{COLORS[color]}m#{text}\e[0m"
      end
    end
  end
end
