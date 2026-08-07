# Launching load tests through the local runner service.
#
# Only available where a runner is actually reachable — the deployed instance has
# no k6 and no results directory, so offering a launch button there would be a
# button that cannot work.
class TestRunsController < ApplicationController
  include RunnerAccess

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

  # Matches the fixed shape in scenarios/chat.js. Stated here so the page can
  # describe what it is about to do.
  #
  # A chat run does not ramp. Everyone joins at once, and the measured window
  # opens when they are all in — so the run describes one load level rather than
  # smearing across every level on the way up.
  JOIN_SECONDS = 10
  CHAT_SECONDS = 50

  # Matches the shape scenarios/enterprise.js takes from config.js, which is NOT
  # chat's: it is a ramping-VUs run that climbs to the requested number of
  # employees, holds them, and comes back down. Only the hold is a measured
  # level, and the whole thing takes nearly three minutes rather than one.
  ENTERPRISE_RAMP_UP_SECONDS = 30
  ENTERPRISE_HOLD_SECONDS = 120
  ENTERPRISE_RAMP_DOWN_SECONDS = 15

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

    # Straight to the run's own page, which is the same address it will keep
    # once it has finished and been imported.
    redirect_to run_path(run["id"])
  rescue Harness::Client::Busy => e
    redirect_to new_test_run_path, alert: e.message
  rescue Harness::Client::Error => e
    redirect_to new_test_run_path, alert: "Could not start the run: #{e.message}"
  end

  private

  def active_run
    health = client.health
    return nil if health.blank? || !health["busy"]

    client.run(health["active_run"])
  rescue Harness::Client::Error
    nil
  end
end
