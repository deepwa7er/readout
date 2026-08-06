# Launching load tests through the local runner service.
#
# Only available where a runner is actually reachable — the deployed instance has
# no k6 and no results directory, so offering a launch button there would be a
# button that cannot work.
class TestRunsController < ApplicationController
  before_action :require_runner

  # Two entry points from one form.
  #
  # chat: one hot room — "what does a room this size cost". The lever is PEOPLE,
  # because in that scenario people fixes both the request rate and the delivery
  # rate together (5 posts/sec × 100 people = 500 deliveries/sec). A request
  # rate alone names a number that cannot be interpreted.
  #
  # enterprise: many rooms with a power-law distribution — "what does a whole
  # company cost on one box". The lever is VUS (concurrent employees), spread
  # across Pareto-distributed rooms (median 4-6, p95 150-250) with HOT_ROOM_SHARE
  # held low so the 10k room behaves like a rarely-written announcement channel.
  SCENARIO_CHAT = "chat".freeze
  SCENARIO_ENTERPRISE = "enterprise".freeze
  ALLOWED_SCENARIOS = [ SCENARIO_CHAT, SCENARIO_ENTERPRISE ].freeze

  # Matches the fixed shape in scenarios/chat.js and scenarios/enterprise.js.
  # Stated here so the page can describe what it is about to do.
  #
  # Neither run ramps. Everyone joins at once, and the measured window opens
  # when they are all in — so the run describes one load level rather than
  # smearing across every level on the way up.
  JOIN_SECONDS = 10
  CHAT_SECONDS = 50

  # One lever per scenario, on purpose.
  #
  # The harness has around twenty, and putting all of them on a form made the
  # common case harder than it should be. The lever that decides the answer is
  # the one the form offers; everything else stays available through the runner's
  # API and the CLI.
  DEFAULT_PEOPLE = 100
  DEFAULT_VUS = 500

  # Seconds between one person's messages. Not sent as a lever — the runner does
  # not accept it, and the scenario's own default is this same value. It is a
  # property of how chatty a room is, not a capacity dial, and three messages a
  # minute is already a busy participant. Stated here only so the page can say so.
  MESSAGE_INTERVAL_SECONDS = 20

  # How many sessions bin/mint-sessions.sh last minted. Asking for more VUs than
  # this does not fail, it just makes them share identities.
  MAX_MINTED_SESSIONS = 1000

  # Levers for a chat run: people in the one hot room, plus enough distinct
  # accounts for them.
  #
  # USER_POOL is derived rather than asked about: two simulated people sharing
  # one account would share a presence record and an unread marker, so the room
  # would think fewer people were in it than the test intends.
  def self.levers_for_chat(people)
    {
      "PEOPLE" => people,
      "USER_POOL" => [ people, MAX_MINTED_SESSIONS ].min
    }
  end

  # Levers for an enterprise run: concurrent employees spread across many rooms.
  #
  # HOT_ROOM_SHARE is held at 0.05 so the 10k room behaves like a rarely-written
  # announcement channel rather than the primary workplace. Without it half the
  # VUs would pile into the hot room and the run would be a second hot-room test
  # rather than an enterprise spread. USER_POOL is derived the same way as for
  # chat — each VU needs its own identity.
  def self.levers_for_enterprise(vus)
    {
      "VUS" => vus,
      "USER_POOL" => [ vus, MAX_MINTED_SESSIONS ].min,
      "HOT_ROOM_SHARE" => "0.05"
    }
  end

  def new
    @scenario = SCENARIO_CHAT
    @people = DEFAULT_PEOPLE
    @vus = DEFAULT_VUS
    @active = active_run
  end

  def create
    scenario = params[:scenario].to_s
    scenario = SCENARIO_CHAT unless ALLOWED_SCENARIOS.include?(scenario)

    levers, people, vus = case scenario
    when SCENARIO_ENTERPRISE
      vus = params[:vus].to_i
      vus = DEFAULT_VUS if vus <= 0
      [ self.class.levers_for_enterprise(vus), nil, vus ]
    else
      people = params[:people].to_i
      people = DEFAULT_PEOPLE if people <= 0
      [ self.class.levers_for_chat(people), people, nil ]
    end

    run = client.start(
      scenario: scenario,
      levers: levers.transform_values(&:to_s),
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
