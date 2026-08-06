require "test_helper"

class RunsFlowTest < ActionDispatch::IntegrationTest
  setup do
    @run = Run.create!(
      stamp: "20260101-120000",
      scenario: "scenarios/ramp.js",
      target: "http://example.test",
      peak_cpu_pct: 558.0,
      total_requests: 14_962,
      config: '{"USER_POOL":"800"}'
    )
    @run.level_stats.create!(vus: 200, room_open_p95: 255, requests_per_second: 34.0, error_count: 0)
    @run.level_stats.create!(vus: 400, room_open_p95: 4301, requests_per_second: 43.3, error_count: 1)
    @run.level_stats.create!(vus: 800, room_open_p95: 17_710, requests_per_second: 40.0, error_count: 21)
  end

  test "index lists runs" do
    get root_path

    assert_response :success
    assert_select ".run-title", text: "20260101-120000"
  end

  # The results page is deliberately minimal: name, settings, and one chart of
  # requests per second. Everything else was removed on purpose.
  test "show is the name, the settings, and the throughput chart" do
    get run_path(@run)

    assert_response :success
    assert_select "h1", text: @run.stamp
    assert_select "h2", text: "Settings"
    assert_select "h2", text: "Requests per second"
    assert_select "svg.chart--plotted"
  end

  test "show states the settings in plain words rather than variable names" do
    get run_path(@run)

    assert_select ".settings dt", text: "distinct accounts used"
    assert_select ".settings dd", text: "800"
  end

  # Units are explained on the page rather than assumed.
  test "show explains what requests per second means" do
    get run_path(@run)

    assert_select "p", /how many actions the server finished each second/
    assert_select "p", /how many simulated users were browsing/
  end

  test "show carries no analysis tables or verdicts any more" do
    get run_path(@run)

    assert_select "table", false
    assert_select ".finding-title", false
    assert_select ".key-row", false
  end

  # A chat or enterprise run holds one population from start to finish, so there
  # is no curve to draw against load. Charted that way it was a lone dot, and a
  # run cancelled before its level was held long enough had nothing at all --
  # which is what "the chart is empty" meant.
  test "a single-level run is charted against time instead of against load" do
    single = Run.create!(stamp: "20260101-130000", scenario: "scenarios/enterprise.js")
    single.level_stats.create!(vus: 250, requests_per_second: 42.0, error_count: 0)
    60.times { |second| single.throughput_samples.create!(at: Time.zone.at(1_700_000_000 + second), requests: 40 + second) }

    get run_path(single)

    assert_response :success
    assert_select "svg.chart--plotted polyline"
    assert_select "p", /drawn against time rather than against people/
    assert_select "p", /measured at/
  end

  # The one case that genuinely has nothing to show says so, rather than
  # rendering an empty frame.
  test "a run that recorded nothing says so" do
    nothing = Run.create!(stamp: "20260101-140000", scenario: "scenarios/enterprise.js")

    get run_path(nothing)

    assert_response :success
    assert_select "svg", false
    assert_select "p", /did not last long enough/
  end

  test "import reports a missing results directory instead of failing silently" do
    original = Rails.configuration.x.campfire_stress.results_root
    Rails.configuration.x.campfire_stress.results_root = "/nonexistent/path"

    post import_runs_path

    assert_redirected_to runs_path
    assert_match(/not found/, flash[:alert])
  ensure
    Rails.configuration.x.campfire_stress.results_root = original
  end
end
