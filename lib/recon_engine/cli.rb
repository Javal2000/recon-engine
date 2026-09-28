# frozen_string_literal: true

module ReconEngine
  # Command-line entry point.
  #
  # Exit codes: 0 reconciled clean, 1 breaks found, 2 the tool itself failed.
  # Keeping 1 and 2 apart lets a scheduler tell bad data from a broken job.
  class CLI
    EXIT_CLEAN  = 0
    EXIT_BREAKS = 1
    EXIT_ERROR  = 2

    COMMANDS = %w[demo generate run eval version help].freeze

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv   = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      catch(:halt) { dispatch(@argv.shift) }
    rescue ReconEngine::Error => e
      @stderr.puts("error: #{e.message}")
      EXIT_ERROR
    rescue Interrupt
      @stderr.puts("interrupted")
      EXIT_ERROR
    end

    private

    def dispatch(command)
      case command
      when "demo"     then demo
      when "generate" then generate
      when "run"      then reconcile
      when "eval"     then evaluate
      when "version"
        @stdout.puts("recon-engine #{ReconEngine::VERSION}")
        EXIT_CLEAN
      when "help", "--help", "-h", nil then help
      else
        @stderr.puts("unknown command #{command.inspect}. Try: #{COMMANDS.join(", ")}")
        EXIT_ERROR
      end
    end

    # --- commands ----------------------------------------------------------

    # Generate synthetic data with known faults, reconcile it, print the report.
    # Needs no credentials, which is why the offline provider is the default.
    def demo
      options = parse(%w[demo]) do |parser, opts|
        parser.on("--dir DIR", "where to write generated data (default: data/)") { |v| opts[:dir] = v }
        parser.on("--seed N", Integer, "generator seed (default: 42)") { |v| opts[:seed] = v }
        parser.on("--rows N", Integer, "ledger rows to generate (default: 2000)") { |v| opts[:rows] = v }
        parser.on("--next-day", "the same books a day later, to compare with --db") { opts[:next_day] = true }
      end
      dir       = options.fetch(:dir, "data")
      generator = Generator.new(seed: options.fetch(:seed, 42), rows: options.fetch(:rows, 2000))
      manifest  = options[:next_day] ? generator.write_next_day(dir) : generator.write(dir)
      describe_demo_data(manifest, dir)

      report = Run.call(
        ledger_path: manifest["paths"]["ledger"],
        warehouse_path: manifest["paths"]["warehouse"],
        config: config_from(options),
        db: options[:db]
      )
      emit(report, options.merge(json: options.fetch(:json, "out/report.json"),
                                 html: options.fetch(:html, "out/report.html")))
    end

    def describe_demo_data(manifest, dir)
      @stdout.puts("generated #{manifest["generator"]["ledger_rows"]} ledger rows and " \
                   "#{manifest["generator"]["warehouse_rows"]} warehouse rows in #{dir}/")
      if (changes = manifest["changes"])
        @stdout.puts("overnight: #{changes["replays_removed"]} replayed rows removed, " \
                     "#{changes["backfilled"].length} dropped rows backfilled, #{changes["new_rows"]} new rows " \
                     "for #{changes["new_day"]} (#{changes["new_missing"].length} never arrived), " \
                     "and the warehouse added #{changes["warehouse_columns_added"].join(", ")}")
      else
        @stdout.puts("injected faults: #{manifest["fault_counts"].map { |k, v| "#{k}=#{v}" }.join(", ")}")
      end
      @stdout.puts
    end

    def generate
      options = parse(%w[generate]) do |parser, opts|
        parser.on("--dir DIR", "output directory (default: data/)") { |v| opts[:dir] = v }
        parser.on("--seed N", Integer, "generator seed (default: 42)") { |v| opts[:seed] = v }
        parser.on("--rows N", Integer, "ledger rows (default: 2000)") { |v| opts[:rows] = v }
        parser.on("--accounts N", Integer, "distinct accounts (default: 10)") { |v| opts[:accounts] = v }
        parser.on("--days N", Integer, "days covered (default: 10)") { |v| opts[:days] = v }
      end

      manifest = Generator.new(
        seed: options.fetch(:seed, 42),
        rows: options.fetch(:rows, 2000),
        accounts: options.fetch(:accounts, 10),
        days: options.fetch(:days, 10)
      ).write(options.fetch(:dir, "data"))

      @stdout.puts(JSON.pretty_generate(manifest.slice("generator", "fault_counts",
                                                       "expected_classifications", "paths")))
      EXIT_CLEAN
    end

    def reconcile
      options = parse(%w[run]) do |parser, opts|
        parser.on("--ledger PATH", "ledger CSV (required)") { |v| opts[:ledger] = v }
        parser.on("--warehouse PATH", "warehouse CSV (required)") { |v| opts[:warehouse] = v }
      end

      ledger    = options[:ledger]    || raise(InputError, "--ledger is required")
      warehouse = options[:warehouse] || raise(InputError, "--warehouse is required")

      report = Run.call(ledger_path: ledger, warehouse_path: warehouse, config: config_from(options), db: options[:db])
      emit(report, options)
    end

    # Generate a dataset, run the whole pipeline with every cluster
    # investigated, and score the agent against the manifest.
    def evaluate
      options = parse(%w[eval]) do |parser, opts|
        parser.on("--seed N", Integer, "generator seed (default: 42)") { |v| opts[:seed] = v }
        parser.on("--rows N", Integer, "ledger rows (default: 600)") { |v| opts[:rows] = v }
        parser.on("--markdown PATH", "also write the results table as Markdown") { |v| opts[:markdown] = v }
      end

      evaluation = Dir.mktmpdir("recon-eval") do |dir|
        manifest = Generator.new(seed: options.fetch(:seed, 42), rows: options.fetch(:rows, 600)).write(dir)
        report   = Run.call(ledger_path: manifest["paths"]["ledger"], warehouse_path: manifest["paths"]["warehouse"],
                            config: config_from({ agent_max_clusters: 100 }.merge(options)))
        Evaluation.new(manifest: manifest, report: report)
      end

      @stdout.puts(evaluation.to_text)
      write_file(options[:json], JSON.pretty_generate(evaluation.to_h)) if options[:json]
      write_file(options[:markdown], "#{evaluation.to_markdown}\n") if options[:markdown]
      EXIT_CLEAN
    end

    def write_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      @stdout.puts("written to #{path}")
    end

    def help
      @stdout.puts(<<~TEXT)
        recon-engine #{ReconEngine::VERSION}. Prove two records of the same activity agree,
        and explain it when they do not.

        USAGE
          bin/recon demo                            generate synthetic data and reconcile it
          bin/recon demo --next-day --db FILE       the same books a day later, compared with the last run
          bin/recon generate --dir data             write synthetic data with injected faults
          bin/recon run --ledger A --warehouse B    reconcile two CSVs
          bin/recon eval --provider gemini          score the agent against a generated answer key
          bin/recon version

        COMMON OPTIONS
          --json PATH             also write the machine-readable report
          --html PATH             also write a self-contained HTML report
          --db PATH               keep run history in a SQLite file and compare with the last run
          --no-agent              deterministic layer only
          --provider NAME         offline | gemini | anthropic | openai | ollama
          --model NAME            provider-specific model id
          --tolerance-cents N     amounts within +/- N cents are equal (default 1)
          --timing-window-days N  settlement lag allowed when matching (default 1)
          --max-clusters N        clusters to investigate per run (default 40)

        EXIT CODES
          0 clean   1 breaks found   2 tool error
      TEXT
      EXIT_CLEAN
    end

    # --- shared plumbing ---------------------------------------------------

    def parse(command)
      options = {}
      parser = OptionParser.new do |p|
        p.banner = "usage: recon #{command.first} [options]"
        yield(p, options) if block_given?
        common_options(p, options)
      end
      parser.parse!(@argv)
      options
    rescue OptionParser::ParseError => e
      raise InputError, e.message
    end

    def common_options(parser, opts)
      parser.on("--json PATH", "write the JSON report to PATH") { |v| opts[:json] = v }
      parser.on("--html PATH", "write a self-contained HTML report to PATH") { |v| opts[:html] = v }
      parser.on("--db PATH", "record the run in a SQLite history file") { |v| opts[:db] = v }
      parser.on("--no-agent", "skip the agent layer entirely") { opts[:agent_enabled] = false }
      parser.on("--provider NAME", "LLM provider (default: offline)") { |v| opts[:agent_provider] = v.to_sym }
      parser.on("--model NAME", "model id for the provider") { |v| opts[:agent_model] = v }
      parser.on("--tolerance-cents N", Integer, "amount tolerance") { |v| opts[:tolerance_cents] = v }
      parser.on("--timing-window-days N", Integer, "settlement window") { |v| opts[:timing_window_days] = v }
      parser.on("--max-clusters N", Integer, "clusters to investigate") { |v| opts[:agent_max_clusters] = v }
      parser.on("--quiet", "suppress the human-readable report") { opts[:quiet] = true }
      parser.on("-h", "--help", "show this message") do
        @stdout.puts(parser)
        throw(:halt, EXIT_CLEAN)
      end
    end

    def config_from(options)
      Config.build(**options.slice(
        :agent_enabled, :agent_provider, :agent_model,
        :tolerance_cents, :timing_window_days, :agent_max_clusters
      ))
    end

    def emit(report, options)
      @stdout.print(Reporting::CliReport.new(report).render) unless options[:quiet]

      if (json_path = options[:json])
        Reporting::JsonReport.write(report, json_path)
        @stdout.puts("JSON report written to #{json_path}")
      end

      if (html_path = options[:html])
        Reporting::HtmlReport.write(report, html_path)
        @stdout.puts("HTML report written to #{html_path}")
      end

      if (history = report.history)
        @stdout.puts(if history.rerun?
                       "History unchanged: same as run #{history.run.number} in #{history.database}"
                     else
                       "History: recorded as run #{history.run.number} in #{history.database}"
                     end)
      end

      report.clean? ? EXIT_CLEAN : EXIT_BREAKS
    end
  end
end
