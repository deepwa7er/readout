# Turns a campfire-stress results directory into persisted records.
#
# Parsing is done once at import rather than per request: the largest metrics.csv
# seen so far is 695k lines, which is several seconds of work and completely
# wasted on every page view.
#
# Importing the same directory twice replaces its derived rows rather than
# duplicating them, so re-importing after an analyzer change is safe and is the
# normal way to refresh a run.
module Analysis
  class Importer
    class MissingMetrics < StandardError; end

    METRICS_FILE = "metrics.csv"
    SERVER_FILE  = "server.csv"
    CONFIG_FILE  = "run-config.txt"
    SUMMARY_FILE = "summary.json"

    attr_reader :directory

    def initialize(directory)
      @directory = Pathname.new(directory)
    end

    # Imports every run directory under a campfire-stress results/ folder.
    def self.import_all(results_root)
      root = Pathname.new(results_root)
      return [] unless root.directory?

      root.children
          .select(&:directory?)
          .select { |dir| dir.join(METRICS_FILE).exist? }
          .sort
          .map { |dir| new(dir).import }
    end

    def import
      raise MissingMetrics, "no #{METRICS_FILE} in #{directory}" unless metrics_path.exist?

      metrics = MetricsFile.parse(metrics_path.to_s)
      trace = ServerTrace.parse(server_path.to_s)
      config = RunConfig.parse(config_path.to_s)
      breakdown = LevelBreakdown.new(metrics, trace)

      window = run_window(metrics)
      run = Run.find_or_initialize_by(stamp: stamp)

      Run.transaction do
        run.assign_attributes(
          path: directory.to_s,
          scenario: config.scenario,
          target: config.target,
          generator: config.generator,
          k6_version: config.k6_version,
          started_at: window && Time.zone.at(window.first),
          imported_at: Time.current,
          peak_cpu_pct: window && trace.peak_cpu(window),
          peak_wal_bytes: window && trace.peak_wal_bytes(window),
          total_broadcasts: total_of(metrics, "campfire_broadcasts_received"),
          total_requests: total_of(metrics, "http_reqs"),
          failed_requests: total_of(metrics, "campfire_errors"),
          config: config.explicit_settings.to_json
        )
        run.save!

        # Derived rows are rebuilt wholesale. Updating in place would leave
        # stale levels behind whenever the segmentation rules change.
        run.level_stats.delete_all
        run.server_samples.delete_all

        breakdown.levels.each { |level| persist_level(run, level) }
        persist_trace(run, trace, window)
      end

      run
    end

    private

    def metrics_path = directory.join(METRICS_FILE)
    def server_path  = directory.join(SERVER_FILE)
    def config_path  = directory.join(CONFIG_FILE)

    def stamp = directory.basename.to_s

    # The span k6 was actually generating load over, used to bound every
    # server-side figure so foreign samples in the file cannot leak in.
    def run_window(metrics)
      first = metrics.vu_timeline.first&.first
      last = metrics.vu_timeline.last&.first
      return nil if first.nil? || last.nil?

      first..last
    end

    def total_of(metrics, name)
      metrics.counter_samples[name].sum(&:value).round
    end

    def persist_level(run, level)
      run.level_stats.create!(
        vus: level.vus,
        window_seconds: level.window_seconds,
        sample_count: level.sample_count,
        requests_per_second: level.requests_per_second,
        megabytes_per_second: level.megabytes_per_second,
        error_count: level.error_count,
        cpu_avg_pct: level.cpu_avg_pct,
        cpu_peak_pct: level.cpu_peak_pct,
        **level.latencies
      )
    end

    def persist_trace(run, trace, window)
      readings = window ? trace.within(window) : trace.readings

      rows = readings.map do |reading|
        {
          run_id: run.id,
          at: Time.zone.at(reading.at),
          cpu_pct: reading.cpu_pct,
          mem_pct: reading.mem_pct,
          load1: reading.load1,
          wal_bytes: reading.wal_bytes,
          db_bytes: reading.db_bytes,
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      ServerSample.insert_all(rows) if rows.any?
    end
  end
end
