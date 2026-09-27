# frozen_string_literal: true

module ReconEngine
  # Orchestrates one reconciliation: profile, match, check, cluster, investigate.
  #
  # The first four phases are pure functions of the input bytes and the config,
  # and produce the same fingerprint on every rerun (see spec/run_spec.rb).
  # Investigation is not, which is why it runs last, cannot influence the earlier
  # phases, is bounded, and degrades one cluster rather than the run.
  class Run
    def self.call(ledger_path:, warehouse_path:, config: Config.build)
      new(
        ledger: Sources::CsvSource.new(ledger_path, name: :ledger),
        warehouse: Sources::CsvSource.new(warehouse_path, name: :warehouse),
        config: config
      ).call
    end

    def initialize(ledger:, warehouse:, config:)
      @ledger    = ledger
      @warehouse = warehouse
      @config    = config
    end

    def call
      started_at = Time.now.utc
      clock      = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      ledger_profile    = Sources::Profile.build(@ledger)
      warehouse_profile = Sources::Profile.build(@warehouse)

      # Profiling streams; matching needs random access. This is the one place
      # rows are held in memory, and where an on-disk sort-merge would go.
      ledger_rows    = @ledger.to_a
      warehouse_rows = @warehouse.to_a

      match_result = Matching::Engine.new(@config).call(ledger: ledger_rows, warehouse: warehouse_rows)

      context = Checks::Context.new(
        config: @config,
        match_result: match_result,
        ledger_profile: ledger_profile,
        warehouse_profile: warehouse_profile,
        ledger_rows: ledger_rows,
        warehouse_rows: warehouse_rows
      )

      breaks   = run_checks(context)
      clusters = Breaks::Clusterer.call(breaks)
      findings = investigate(clusters, context, breaks)

      Reporting::Report.new(
        config: @config,
        inputs: input_descriptors(ledger_profile, warehouse_profile),
        ledger_profile: ledger_profile,
        warehouse_profile: warehouse_profile,
        match_result: match_result,
        breaks: breaks,
        clusters: clusters,
        findings: findings,
        started_at: started_at,
        duration_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock
      )
    end

    private

    # Sorted by content-addressed id, so neither registration order nor hash
    # iteration order can reach the report.
    def run_checks(context)
      Checks::Base.all
                  .flat_map { |check_class| check_class.new(@config).call(context) }
                  .sort_by { |record| [record.type.to_s, record.id] }
    end

    def investigate(clusters, context, breaks)
      return [] unless @config.agent?
      return [] if clusters.empty?

      targets      = investigation_targets(clusters)
      client       = LLM::Client.build(@config)
      tools        = Agent::Tools.new(context: context, breaks: breaks)
      investigator = Agent::Investigator.new(client: client, tools: tools, config: @config)

      targets.map { |cluster| investigator.investigate(cluster) }
    rescue ProviderError => e
      # Only building the client can land here; the investigator contains its
      # own provider failures. A provider we cannot construct is a configuration
      # problem, not a data problem: say so on every cluster and let the
      # deterministic report stand.
      targets.map do |cluster|
        Agent::Finding.degraded_for(cluster.id, provider: @config.agent_provider.to_s, model: @config.agent_model,
                                                model_backed: false, reason: e.message)
      end
    end

    # Ranking the budget purely by dollar magnitude would miss the case this
    # engine exists to catch: a whole feed arriving a day late is thousands of
    # breaks worth zero dollars. So most of the budget goes by money and the
    # rest by volume, and the union is investigated in report order.
    def investigation_targets(clusters)
      budget    = @config.agent_max_clusters
      position  = clusters.each_with_index.to_h
      by_money  = clusters.first(budget)
      by_volume = clusters.sort_by { |c| [-c.count, c.id] }.first([budget / 4, 1].max)

      (by_money | by_volume).sort_by { |c| position.fetch(c) }
    end

    def input_descriptors(ledger_profile, warehouse_profile)
      [
        { role: :ledger, path: @ledger.path, digest: @ledger.digest, rows: ledger_profile.row_count },
        { role: :warehouse, path: @warehouse.path, digest: @warehouse.digest, rows: warehouse_profile.row_count }
      ]
    end
  end
end
