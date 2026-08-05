# Launching load tests through the local runner service.
#
# Only available where a runner is actually reachable — the deployed instance has
# no k6 and no results directory, so offering a launch button there would be a
# button that cannot work.
class TestRunsController < ApplicationController
  before_action :require_runner

  # One scenario, one lever.
  #
  # The others are still reachable from the CLI, but the UI offers only this: a
  # fixed request rate. The VU-based scenarios measure "people", who pause
  # between actions — so when the server slows they slow with it and the request
  # rate falls, which made a saturated server look like a quiet one. Requests per
  # second is the number worth choosing, so it is the only thing to choose.
  SCENARIO = "chat".freeze

  # Matches the fixed shape in scenarios/arrival.js. Stated here so the page can
  # describe what it is about to do.
  RAMP_SECONDS = 20
  HOLD_SECONDS = 30

  # Two levers, on purpose.
  #
  # The harness has around twenty, and putting all of them on a form made the
  # common case ("run more traffic at it") harder than it should be. These two
  # both mean the same thing in the same direction — turn either up and the
  # server does more work — which is the only mental model the form needs.
  #
  # Everything else stays available through the runner's API and the CLI; it is
  # hidden here, not removed.
  DEFAULT_PEOPLE = 100

  # Seconds between one person's messages. Fixed rather than exposed: it is a
  # property of how chatty a room is, not a capacity dial, and three messages a
  # minute is already a busy participant.
  MESSAGE_INTERVAL_SECONDS = 20

  # How many sessions bin/mint-sessions.sh last minted. Asking for more VUs than
  # this does not fail, it just makes them share identities.
  MAX_MINTED_SESSIONS = 1000

  # People in the chat, plus enough distinct accounts for them.
  #
  # USER_POOL is derived rather than asked about: two simulated people sharing
  # one account would share a presence record and an unread marker, so the room
  # would think fewer people were in it than the test intends.
  def self.levers_for(people)
    {
      "PEOPLE" => people,
      "MESSAGE_INTERVAL_SECONDS" => MESSAGE_INTERVAL_SECONDS,
      "USER_POOL" => [ people, MAX_MINTED_SESSIONS ].min
    }
  end

  def new
    @people = DEFAULT_PEOPLE
    @active = active_run
  end

  def create
    people = params[:people].to_i

    run = client.start(
      scenario: SCENARIO,
      levers: self.class.levers_for(people).transform_values(&:to_s),
      note: params[:note]
    )
    redirect_to test_run_path(run["id"])
  rescue Harness::Client::Busy => e
    redirect_to new_test_run_path, alert: e.message
  rescue Harness::Client::Error => e
    redirect_to new_test_run_path, alert: "Could not start the run: #{e.message}"
  end

  # The page shell. Its status fragment is loaded and refreshed by #status, so
  # the log is not fetched here.
  def show
    @run = client.run(params[:id])
  rescue Harness::Client::Error => e
    redirect_to new_test_run_path, alert: e.message
  end

  # The polled fragment. Kept separate from #show so the page shell is not
  # re-rendered every two seconds.
  def status
    @run = client.run(params[:id])
    @log = client.log(params[:id])
    render partial: "status", locals: { run: @run, log: @log }
  rescue Harness::Client::Error => e
    render plain: e.message, status: :service_unavailable
  end

  # Feeds the live chart. Carries the run's state too, so the chart knows when to
  # stop polling without a second request.
  def progress
    data = client.progress(params[:id]) || {}
    running = client.run(params[:id])["state"] == "running"
    render json: data.merge("running" => running)
  rescue Harness::Client::Error => e
    render json: { error: e.message }, status: :service_unavailable
  end

  # Returns you to wherever you pressed Stop, since the button now appears on
  # the index and the new-test page as well as the run's own page.
  def cancel
    client.cancel(params[:id])
    redirect_back fallback_location: test_run_path(params[:id]), notice: "Load test stopped."
  rescue Harness::Client::Error => e
    redirect_back fallback_location: test_run_path(params[:id]), alert: e.message
  end

  # Ships a finished run's results into this dashboard.
  #
  # Delegated to the runner rather than imported directly: the results are CSV on
  # the runner's disk, and this app is not necessarily on that machine. Asking the
  # runner to publish works from either instance, which is what keeps this a
  # single app rather than one that behaves differently depending on where it
  # happens to be running.
  #
  # Runs publish themselves on completion, so this is the retry path.
  def publish
    client.publish(params[:id])
    redirect_to test_run_path(params[:id]),
      notice: "Publishing results — the dashboard will update shortly."
  rescue Harness::Client::Error => e
    redirect_to test_run_path(params[:id]), alert: e.message
  end

  private

  def client
    @client ||= Harness::Client.new
  end

  def active_run
    health = client.health
    return nil if health.blank? || !health["busy"]

    client.run(health["active_run"])
  rescue Harness::Client::Error
    nil
  end

  def require_runner
    return if client.available?

    redirect_to runs_path,
      alert: "No runner is reachable. Load tests are launched from the machine " \
             "running the harness — start it with `bin/runner` in campfire-stress."
  end
end
