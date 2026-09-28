# frozen_string_literal: true

module ReconEngine
  class Generator
    # The same books a day later, so run history (--db) has something to
    # compare.
    #
    # Overnight the warehouse team removed the replayed rows and backfilled
    # half of what was dropped. A new day of activity arrived with a few rows
    # missing downstream, and the warehouse started sending a batch_id column.
    # The warehouse file is reshuffled, so most breaks come back on different
    # row numbers, which is exactly what the history's stable keys are for.
    class NextDay
      NEW_MISSING  = 3
      ADDED_COLUMN = "batch_id"

      def initialize(generator)
        @generator = generator
      end

      def write(dir)
        ledger, warehouse, manifest = @generator.build
        settings  = manifest["generator"]
        new_day   = Date.iso8601(settings["start_date"]) + settings["days"]
        backfill  = backfilled(manifest)
        fresh_ledger, fresh_warehouse, fresh_manifest = new_activity(settings, new_day).build

        # Array#uniq is enough to drop the replays: they are exact copies.
        warehouse = (warehouse.uniq + ledger.select { |row| backfill.include?(row["txn_id"]) } + fresh_warehouse)
                    .shuffle(random: Random.new(settings["seed"]))
                    .map { |row| row.merge(ADDED_COLUMN => "WH-#{new_day.strftime("%Y%m%d")}") }
        ledger += fresh_ledger

        changes = {
          "replays_removed" => manifest["fault_counts"].fetch("duplicated", 0),
          "backfilled" => backfill,
          "new_day" => new_day.iso8601,
          "new_rows" => fresh_ledger.length,
          "new_missing" => fresh_manifest["faults"].map { |fault| fault["txn_id"] },
          "warehouse_columns_added" => [ADDED_COLUMN]
        }
        Generator.write_files(dir, ledger, warehouse, manifest_for(settings, ledger, warehouse, changes))
      end

      private

      def backfilled(manifest)
        dropped = manifest["faults"].select { |fault| fault["kind"] == "missing" }.map { |fault| fault["txn_id"] }
        dropped.first(dropped.length / 2)
      end

      # One more day's worth of rows, numbered on from the first file and
      # clean apart from a few that never reach the warehouse.
      def new_activity(settings, new_day)
        Generator.new(
          seed: settings["seed"] + 1,
          rows: [settings["ledger_rows"] / settings["days"], NEW_MISSING + 1].max,
          accounts: settings["accounts"],
          days: 1,
          start_date: new_day,
          faults: DEFAULT_FAULTS.transform_values { 0 }.merge(missing: NEW_MISSING),
          first_id: settings["ledger_rows"] + 1
        )
      end

      def manifest_for(settings, ledger, warehouse, changes)
        {
          "generator" => settings.merge("ledger_rows" => ledger.length, "warehouse_rows" => warehouse.length,
                                        "next_day" => true),
          "changes" => changes
        }
      end
    end
  end
end
