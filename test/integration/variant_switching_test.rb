require "test_helper"

# Switching which build of Campfire the next test measures, from the dashboard.
#
# The runner is stubbed: it drives a real deployment on another machine, and a
# test suite must not redeploy anything. What is worth covering here is that the
# page reports what the runner said rather than what it hoped for — including
# every way the runner can say no.
class VariantSwitchingTest < ActionDispatch::IntegrationTest
  # Stands in for the runner service. Records what it was asked to switch to, so
  # a test can tell "the button posted" from "the button looked right".
  class FakeRunner
    attr_reader :switched_to

    def initialize(payload:, on_switch: nil)
      @payload = payload
      @on_switch = on_switch
    end

    def available? = true
    def health = { "ok" => true, "busy" => false }
    def variants = @payload

    def switch_variant(name)
      @switched_to = name
      raise @on_switch if @on_switch
    end
  end

  DEPLOYED = {
    "current" => {
      "variant" => "stock",
      "image" => "ghcr.io/basecamp/once-campfire@sha256:0c50e967",
      "env" => "CAMPFIRE_BATCH_UNREAD=0,RAILS_ENV=performance"
    },
    "state" => { "state" => "idle" },
    "variants" => [
      { "name" => "stock", "description" => "Campfire as it ships." },
      { "name" => "tuned", "description" => "Pragmas plus both flags." }
    ]
  }.freeze

  # Swaps the constructor for the duration of a test. There is no mocking
  # library here, and this needs no more than one substitution — removing the
  # singleton method afterwards restores the ordinary Class#new, since
  # Harness::Client does not define its own.
  def with_runner(runner)
    Harness::Client.define_singleton_method(:new) { |*| runner }
    yield
  ensure
    Harness::Client.singleton_class.remove_method(:new)
  end

  test "the new-test page names the server the run will measure" do
    with_runner(FakeRunner.new(payload: DEPLOYED)) do
      get new_test_run_path

      assert_response :success
      assert_select "turbo-frame#server-variant"
    end
  end

  test "the frame names what is deployed and offers the others" do
    with_runner(FakeRunner.new(payload: DEPLOYED)) do
      get variant_path

      assert_response :success
      assert_select "strong", text: "stock"
      assert_select "form[action=?]", switch_variant_path("tuned")

      # Never a button to switch to what is already running.
      assert_select "form[action=?]", switch_variant_path("stock"), count: 0
    end
  end

  test "switching asks the runner and reports that it started" do
    runner = FakeRunner.new(payload: DEPLOYED.merge("state" => { "state" => "switching", "target" => "tuned" }))

    with_runner(runner) do
      post switch_variant_path("tuned")

      assert_response :success
      assert_equal "tuned", runner.switched_to
      assert_select "strong", /Switching the server to tuned/
    end
  end

  # The refusal that matters most: a switch restarts the server, so the runner
  # rejects one while a run is measuring. Submitted from inside a Turbo Frame, a
  # redirect would have its frame extracted and the flash dropped — so the
  # refusal has to come back inside the frame or it is not seen at all.
  test "a refusal while a run is active is shown rather than lost" do
    runner = FakeRunner.new(
      payload: DEPLOYED,
      on_switch: Harness::Client::Busy.new("a load test is running — switching now would restart the server under it")
    )

    with_runner(runner) do
      post switch_variant_path("tuned")

      assert_response :success
      assert_select ".figure--bad", /a load test is running/
    end
  end

  test "a switch that failed on the runner is reported with its cause" do
    failed = DEPLOYED.merge(
      "state" => { "state" => "failed", "target" => "tuned", "error" => "once update: hostname already in use" }
    )

    with_runner(FakeRunner.new(payload: failed)) do
      get variant_path

      assert_select ".figure--bad", /once update: hostname already in use/
    end
  end

  # A server whose deployed image does not match what was deployed from here.
  # Saying so is the entire value of reading it off the box rather than
  # remembering what was last requested.
  test "an unidentified server is called out rather than shown as a variant" do
    unknown = DEPLOYED.merge("current" => DEPLOYED["current"].merge("variant" => "unknown"))

    with_runner(FakeRunner.new(payload: unknown)) do
      get variant_path

      assert_select ".figure--bad", /does not match what was deployed/
    end
  end

  test "a machine that cannot be read says so instead of blanking the frame" do
    unreadable = { "state" => { "state" => "idle" }, "variants" => [], "current_error" => "runner unreachable" }

    with_runner(FakeRunner.new(payload: unreadable)) do
      get variant_path

      assert_select "strong", /could not be read/
      assert_select "p", /runner unreachable/
    end
  end
end
