# frozen_string_literal: true

module ReconEngine
  # Run history, kept in a SQLite file named with --db.
  #
  # A reconciliation that runs every day is only half read without it: the
  # question on day two is not "what is broken" but "what is new, what has been
  # broken since Monday, and what did yesterday's fix actually fix".
  module History
    # The sqlite3 gem is loaded here and nowhere else, so the engine still
    # runs on the standard library alone when --db isn't used.
    def self.load_driver
      require "sqlite3"
    rescue LoadError
      raise HistoryError, "--db needs the sqlite3 gem. Run `bundle install` or `gem install sqlite3`."
    end

    # Records the run and returns how it compares with the one before.
    def self.record(report, keys, path:)
      Store.open(path) { |store| store.record(report, keys) }
    end

    # Every run, every break in it under its stable key, and each source's
    # schema. Only ever appended to.
    class Store
      VERSION = 1

      SCHEMA = <<~SQL
        CREATE TABLE runs (
          number                 INTEGER PRIMARY KEY,
          started_at             TEXT    NOT NULL,
          fingerprint            TEXT    NOT NULL,
          config_digest          TEXT    NOT NULL,
          ledger_digest          TEXT    NOT NULL,
          warehouse_digest       TEXT    NOT NULL,
          break_count            INTEGER NOT NULL,
          row_level_impact_cents INTEGER NOT NULL,
          engine_version         TEXT    NOT NULL
        );
        CREATE TABLE run_breaks (
          run             INTEGER NOT NULL REFERENCES runs (number),
          break_key       TEXT    NOT NULL,
          break_id        TEXT    NOT NULL,
          type            TEXT    NOT NULL,
          row_level       INTEGER NOT NULL,
          magnitude_cents INTEGER NOT NULL,
          first_seen      INTEGER NOT NULL REFERENCES runs (number),
          PRIMARY KEY (run, break_key)
        );
        CREATE TABLE run_schemas (
          run     INTEGER NOT NULL REFERENCES runs (number),
          source  TEXT    NOT NULL,
          columns TEXT    NOT NULL,
          PRIMARY KEY (run, source)
        );
      SQL

      RUN_COLUMNS = "number, started_at, fingerprint, config_digest, break_count, row_level_impact_cents"

      def self.open(path)
        store = new(path)
        yield store
      ensure
        store&.close
      end

      attr_reader :path

      def initialize(path)
        History.load_driver
        @path = path
        guarded do
          FileUtils.mkdir_p(File.dirname(path))
          @db = SQLite3::Database.new(path)
          @db.busy_timeout = 5_000
          migrate
        end
      rescue HistoryError
        # Otherwise the handle outlives the error, and on Windows the file
        # stays locked until the process exits.
        close
        raise
      end

      # A rerun of exactly the latest run's inputs and settings is not stored
      # again. Otherwise a retried job would age every open break by a day.
      def record(report, keys)
        guarded do
          number, rerun = @db.transaction(:immediate) do
            latest = latest_run
            if latest&.fingerprint == report.deterministic_fingerprint
              [latest.number, true]
            else
              [insert(report, keys, latest), false]
            end
          end
          summarize(number, rerun: rerun)
        end
      end

      def summarize(number, rerun: false)
        run      = run_info(number) || raise(HistoryError, "#{path} has no run #{number}")
        previous = run_info(@db.get_first_value("SELECT MAX(number) FROM runs WHERE number < ?", [number]))
        now      = entries(number)
        before   = previous ? entries(previous.number) : {}

        Summary.new(
          database: path, run: run, previous: previous, rerun: rerun,
          opened: now.values.select { |entry| entry.first_seen_run == number },
          still_open: now.values.reject { |entry| entry.first_seen_run == number },
          resolved: before.values.reject { |entry| now.key?(entry.key) },
          schema_changes: previous ? schema_changes(previous.number, number) : []
        )
      end

      def run_count = @db.get_first_value("SELECT COUNT(*) FROM runs")

      def close
        @db.close if @db && !@db.closed?
      end

      private

      def guarded
        yield
      rescue SQLite3::Exception => e
        raise HistoryError, "run history #{path}: #{e.message}"
      end

      # user_version is 0 in a brand-new file. A higher number than ours means
      # a newer engine wrote it, and guessing at its tables would be worse
      # than stopping.
      def migrate
        version = @db.get_first_value("PRAGMA user_version")
        return if version == VERSION
        raise HistoryError, "#{path} was written by a newer recon-engine (history v#{version})" if version > VERSION

        @db.transaction do
          @db.execute_batch(SCHEMA)
          @db.execute("PRAGMA user_version = #{VERSION}")
        end
      end

      def insert(report, keys, latest)
        @db.execute(<<~SQL, run_values(report))
          INSERT INTO runs (started_at, fingerprint, config_digest, ledger_digest, warehouse_digest,
                            break_count, row_level_impact_cents, engine_version)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        number = @db.last_insert_row_id
        insert_breaks(number, report.breaks, keys, latest ? streaks(latest.number) : {})
        { ledger: report.ledger_profile, warehouse: report.warehouse_profile }.each do |source, profile|
          @db.execute("INSERT INTO run_schemas VALUES (?, ?, ?)", [number, source.to_s, JSON.generate(profile.schema)])
        end
        number
      end

      def run_values(report)
        digests = report.inputs.to_h { |input| [input[:role], input[:digest]] }
        [report.started_at.iso8601, report.deterministic_fingerprint, report.config.deterministic_digest,
         digests.fetch(:ledger), digests.fetch(:warehouse), report.break_count, report.row_level_impact_cents,
         ReconEngine::VERSION]
      end

      # A break that was open last run carries its first_seen forward. One
      # that wasn't, including one that went away and came back, starts here.
      def insert_breaks(number, breaks, keys, carried)
        statement = @db.prepare("INSERT INTO run_breaks VALUES (?, ?, ?, ?, ?, ?, ?)")
        breaks.each do |record|
          key = keys.fetch(record.id)
          statement.execute(number, key, record.id, record.type.to_s, record.row_level? ? 1 : 0,
                            record.magnitude_cents, carried.fetch(key, number))
        end
      ensure
        statement&.close
      end

      def streaks(number)
        @db.execute("SELECT break_key, first_seen FROM run_breaks WHERE run = ?", [number]).to_h
      end

      def latest_run
        row = @db.get_first_row("SELECT #{RUN_COLUMNS} FROM runs ORDER BY number DESC LIMIT 1")
        row && RunInfo.new(*row)
      end

      def run_info(number)
        return nil if number.nil?

        row = @db.get_first_row("SELECT #{RUN_COLUMNS} FROM runs WHERE number = ?", [number])
        row && RunInfo.new(*row)
      end

      # key => Entry, with the date its streak began.
      def entries(number)
        rows = @db.execute(<<~SQL, [number])
          SELECT b.break_key, b.break_id, b.type, b.row_level, b.magnitude_cents, b.first_seen, r.started_at
          FROM run_breaks b JOIN runs r ON r.number = b.first_seen
          WHERE b.run = ?
          ORDER BY b.break_key
        SQL
        rows.to_h do |row|
          entry = Entry.new(*row)
          [entry.key, entry.with(row_level: entry.row_level == 1)]
        end
      end

      def schema_changes(before, after)
        was = schemas(before)
        now = schemas(after)
        (was.keys & now.keys).sort.flat_map { |source| SchemaChange.between(source, was[source], now[source]) }
      end

      def schemas(number)
        @db.execute("SELECT source, columns FROM run_schemas WHERE run = ?", [number])
           .to_h { |source, columns| [source, JSON.parse(columns)] }
      end
    end
  end
end
