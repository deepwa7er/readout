require "test_helper"
require "tmpdir"

module Analysis
  # End-to-end coverage of the real parsing path, against a results directory
  # built on the fly. Written rather than committed as fixture files so the
  # shape of the input is visible right here -- and so the test never depends on
  # an 80MB artifact.
  class ImporterTest < ActiveSupport::TestCase
    METRICS_HEADER = "metric_name,timestamp,metric_value,check,error,error_code," \
                     "expected_response,group,method,name,proto,scenario,service," \
                     "status,subproto,tls_version,url,extra_tags,metadata".freeze

    def write_run(dir, stamp:, base: 1_700_000_000)
      run_dir = File.join(dir, stamp)
      FileUtils.mkdir_p(run_dir)

      rows = [ METRICS_HEADER ]
      server = [ "ts,cpu_pct,mem_pct,load1,wal_bytes,db_bytes" ]

      # Two plateaus, 60s each, with a level revisited on the way down so the
      # contiguous-segment rule is genuinely exercised.
      schedule = ([ 10 ] * 60) + ([ 20 ] * 60) + ([ 10 ] * 40)

      schedule.each_with_index do |vus, offset|
        at = base + offset
        rows << "vus,#{at},#{vus},,,,,,,,,,,,,,,,"
        rows << "campfire_room_open,#{at},#{vus * 10},,,,true,,GET,room,,,,200,,,,endpoint=room_open,"
        rows << "http_reqs,#{at},1,,,,true,,GET,room,,,,200,,,,endpoint=room_open,"
        rows << "data_received,#{at},#{1_048_576},,,,,,,,,,,,,,,,"
        server << "#{at},#{vus * 20}.0,5.0,0.5,#{1024 * offset},2048"
      end

      File.write(File.join(run_dir, "metrics.csv"), rows.join("\n") + "\n")
      File.write(File.join(run_dir, "server.csv"), server.join("\n") + "\n")
      File.write(File.join(run_dir, "run-config.txt"), <<~CONFIG)
        stamp=#{stamp}
        scenario=scenarios/ramp.js
        target=http://example.test
        generator=test-host
        k6=k6 v2.1.0
        VUS=<config default>
        USER_POOL=800
      CONFIG

      run_dir
    end

    test "imports a results directory into levels and samples" do
      Dir.mktmpdir do |dir|
        write_run(dir, stamp: "20260101-000000")
        run = Importer.new(File.join(dir, "20260101-000000")).import

        assert_equal "20260101-000000", run.stamp
        assert_equal "scenarios/ramp.js", run.scenario
        assert_equal "http://example.test", run.target
        assert_equal [ 10, 20 ], run.level_stats.pluck(:vus)

        slow = run.level_stats.find_by(vus: 20)
        assert_equal 200.0, slow.room_open_p95
        assert_in_delta 1.0, slow.requests_per_second, 0.05
        assert_in_delta 1.0, slow.megabytes_per_second, 0.05
      end
    end

    # The series a single-level run is charted against. It has to cover the whole
    # run, second by second, or the chart it feeds is the empty frame this exists
    # to replace.
    test "records requests completed per second across the whole run" do
      Dir.mktmpdir do |dir|
        path = write_run(dir, stamp: "20260101-000005")
        run = Importer.new(path).import

        assert_equal 160, run.throughput_samples.count, "one row per second of the run"
        assert_equal [ 1 ], run.throughput_samples.pluck(:requests).uniq
      end
    end

    # A second in which nothing completed is a measurement, not a missing one.
    test "seconds with no completed requests are recorded as zero" do
      Dir.mktmpdir do |dir|
        path = write_run(dir, stamp: "20260101-000006")

        # A ten-second stall in the middle, with the VU timeline unbroken so the
        # run's window still spans it.
        metrics = File.join(path, "metrics.csv")
        kept = File.readlines(metrics).reject do |line|
          line.start_with?("http_reqs,") && (1_700_000_070..1_700_000_079).cover?(line.split(",")[1].to_i)
        end
        File.write(metrics, kept.join)

        run = Importer.new(path).import
        stalled = run.throughput_samples.where(at: Time.zone.at(1_700_000_070)..Time.zone.at(1_700_000_079))

        assert_equal 10, stalled.count
        assert_equal [ 0 ], stalled.pluck(:requests).uniq
      end
    end

    # Stragglers finishing their sessions after a run ends hold a constant, tiny
    # VU count for long enough to look like a plateau. It is not a level, and
    # letting it become one draws a load curve out of the run's dying tail.
    test "an idle tail is not imported as a level" do
      Dir.mktmpdir do |dir|
        path = write_run(dir, stamp: "20260101-000007")

        # 40 seconds at 2 VUs with no requests, appended after the run proper.
        File.open(File.join(path, "metrics.csv"), "a") do |file|
          (0..39).each { |offset| file.puts "vus,#{1_700_000_160 + offset},2,,,,,,,,,,,,,,,," }
        end

        run = Importer.new(path).import

        assert_equal [ 10, 20 ], run.level_stats.pluck(:vus)
      end
    end

    test "only settings explicitly set for the run are kept" do
      Dir.mktmpdir do |dir|
        write_run(dir, stamp: "20260101-000001")
        run = Importer.new(File.join(dir, "20260101-000001")).import

        assert_equal({ "USER_POOL" => "800" }, run.settings)
      end
    end

    test "re-importing replaces derived rows instead of duplicating them" do
      Dir.mktmpdir do |dir|
        path = write_run(dir, stamp: "20260101-000002")

        first = Importer.new(path).import
        levels = first.level_stats.count
        samples = first.server_samples.count
        throughput = first.throughput_samples.count

        second = Importer.new(path).import

        assert_equal first.id, second.id
        assert_equal levels, second.level_stats.count
        assert_equal samples, second.server_samples.count
        assert_equal throughput, second.throughput_samples.count
      end
    end

    # Server samples recorded outside the run's own window must not leak in.
    # Before the sampler's process handling was fixed, every run leaked a remote
    # loop that kept appending to the file for as long as an hour, recording
    # load generated by later runs.
    test "server figures ignore samples outside the run window" do
      Dir.mktmpdir do |dir|
        path = write_run(dir, stamp: "20260101-000003")

        File.open(File.join(path, "server.csv"), "a") do |file|
          file.puts "#{1_700_100_000},799.0,9.0,9.0,#{99 * 1_048_576},4096"
        end

        run = Importer.new(path).import

        assert_equal 400.0, run.peak_cpu_pct, "peak must come from the run's own window"
        assert_not_equal 99 * 1_048_576, run.peak_wal_bytes
      end
    end

    test "import_all skips directories without metrics" do
      Dir.mktmpdir do |dir|
        write_run(dir, stamp: "20260101-000004")
        FileUtils.mkdir_p(File.join(dir, "not-a-run"))

        runs = Importer.import_all(dir)

        assert_equal 1, runs.length
      end
    end

    test "raises a clear error when metrics are missing" do
      Dir.mktmpdir do |dir|
        assert_raises(Importer::MissingMetrics) do
          Importer.new(File.join(dir, "nope")).import
        end
      end
    end
  end
end
