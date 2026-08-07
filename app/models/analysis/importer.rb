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
    class MalformedProgress < StandardError; end

    METRICS_FILE  = "metrics.csv"
    SERVER_FILE   = "server.csv"
    CONFIG_FILE   = "run-config.txt"
    SUMMARY_FILE  = "summary.json"
    PROGRESS_FILE = "progress.json"

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
          variant: config.variant,
          server_image: config.server_image,
          server_digest: config.server_digest,
          server_env: config.server_env,
          started_at: window && Time.zone.at(window.first),
          imported_at: Time.current,
          peak_cpu_pct: window && trace.peak_cpu(window),
          peak_wal_bytes: window && trace.peak_wal_bytes(window),
          total_broadcasts: total_of(metrics, "campfire_broadcasts_received"),
          total_requests: total_of(metrics, "http_reqs"),
          unanswered_requests: metrics.unanswered_requests,
          harness_errors: total_of(metrics, "campfire_errors"),
          config: config.explicit_settings.to_json
        )
        run.save!

        # Derived rows are rebuilt wholesale. Updating in place would leave
        # stale levels behind whenever the segmentation rules change.
        run.level_stats.delete_all
        run.server_samples.delete_all
        run.throughput_samples.delete_all
        RunProgress.where(run: run).delete_all

        breakdown.levels.each { |level| persist_level(run, level) }
        persist_trace(run, trace, window)
        persist_throughput(run, metrics, window)
        persist_progress(run)
      end

      # The sample tables are written with insert_all, which goes straight to the
      # database and past the associations this method emptied a moment earlier.
      # Without resetting them, the run handed back reports no samples at all
      # while the rows sit there in the table.
      run.level_stats.reset
      run.server_samples.reset
      run.throughput_samples.reset
      run.reload_progress

      run
    end

    private

    def metrics_path  = directory.join(METRICS_FILE)
    def server_path   = directory.join(SERVER_FILE)
    def config_path   = directory.join(CONFIG_FILE)
    def progress_path = directory.join(PROGRESS_FILE)

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

    # Requests completed per second, for the whole run.
    #
    # This is what a single-level run can be charted against: chat and enterprise
    # runs hold one population from start to finish, so throughput against load
    # is a single point and only throughput against time has a shape. k6 stamps
    # every sample to the whole second, which is exactly the resolution wanted
    # here, so the series is a tally rather than a rolling window.
    #
    # Every second in the run's window gets a row, including the ones nothing
    # completed in. See ThroughputSample for why a zero is not the same as a gap.
    def persist_throughput(run, metrics, window)
      return if window.nil?

      completed = Hash.new(0.0)
      metrics.counter_samples["http_reqs"].each do |sample|
        completed[sample.at] += sample.value if window.cover?(sample.at)
      end

      rows = window.map do |second|
        {
          run_id: run.id,
          at: Time.zone.at(second),
          requests: completed[second].round,
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      ThroughputSample.insert_all(rows) if rows.any?
    end

    # The series the run's charts are drawn from, taken whole from the runner.
    #
    # Not computed here, and deliberately: they come from k6's JSON output at
    # 33ms resolution, and the runner has already computed them once to feed the
    # live chart. Parsing that file a second time in another language would put
    # two implementations of the same arithmetic in the same product, which is
    # exactly how the two views came to disagree. See RunProgress.
    #
    # Absent for runs that finished before the runner wrote this file. Those
    # pages say so rather than drawing an empty chart; `bin/runner
    # --rebuild-progress`, on the machine holding results/, is what fills them in.
    def persist_progress(run)
      return unless progress_path.exist?

      RunProgress.create!(run: run, payload: JSON.parse(progress_path.read))
    rescue JSON::ParserError => e
      # Loud rather than skipped. The file is written atomically, so a
      # half-written one means something is wrong with the run's output, and a
      # page silently missing its charts is the failure this whole change exists
      # to remove.
      raise MalformedProgress, "#{progress_path} is not valid JSON: #{e.message}"
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
