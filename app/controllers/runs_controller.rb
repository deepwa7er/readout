class RunsController < ApplicationController
  def index
    @runs = Run.newest_first.includes(:level_stats)
    @results_root = Rails.configuration.x.campfire_stress.results_root

    # The deployed instance has no results directory: raw results are written by
    # the harness on the dev box and only the database is shipped up. Knowing
    # which kind of instance this is keeps the page from advertising a path that
    # does not exist here and a rescan that cannot work.
    @results_available = @results_root.present? && Dir.exist?(@results_root)

    # One call, not two: /healthz reports both that a runner is there and
    # whether it is busy, and this sits in the page's critical path.
    #
    # Probed rather than inferred from the environment: launching is offered only
    # where a runner answers, which is the machine with k6 on it.
    health = Harness::Client.new.health
    @runner_available = health.present?

    # A running test must be stoppable from here. Previously the only Stop button
    # lived on that run's own page, so leaving it meant hunting for the run again
    # while load kept hitting the server.
    @active_test_id = health["active_run"] if health.present? && health["busy"]
  end

  # One page per run, whether it is happening or happened.
  #
  # A run in flight and the same run afterwards used to be two pages at two
  # addresses, reached different ways and behaving differently. They are one
  # thing: /runs/<stamp> is that thing, and what it can show depends only on how
  # far along the run is.
  #
  # Runs are addressed by stamp rather than by database id because a live run
  # has no row yet — rows appear at import — while the stamp already identifies
  # the same run to the runner, to its results directory, and to this database.
  # It is also stable across instances, which ids are not: bin/publish replaces
  # the whole database file.
  def show
    @run = Run.includes(:level_stats).find_by(stamp: params[:stamp])

    # The runner is asked only when this instance has no record of the run.
    # Once a run is imported it has finished, so the runner has nothing to add —
    # which means an imported run opens with no network call at all, and keeps
    # opening when the runner is down or was never there.
    @live = @run ? nil : live_run

    raise ActiveRecord::RecordNotFound, "no run #{params[:stamp]}" if @run.nil? && @live.nil?
  end

  # The running request totals, for a run still in flight.
  #
  # A fragment because they climb while the run goes: the page refreshes this
  # rather than waiting for the results to be imported to say how much the
  # server was asked for and how much of it went unanswered.
  def requests
    live = client.progress(params[:stamp]) || {}
    received = live["requests"]
    unanswered = live["unanswered"]

    render partial: "runs/live_requests", locals: {
      stamp: params[:stamp],
      received: received,
      unanswered: unanswered,
      share: (unanswered.to_f / received if received.to_i.positive? && unanswered),
      # Stops refreshing when the run does: after that the totals are final.
      active: live_run&.dig("state") == "running"
    }
  end

  # The live status fragment: state, and the means to stop it. Polled, which is
  # why it is a fragment rather than part of the page.
  def status
    live = live_run
    return render partial: "runs/forgotten", locals: { stamp: params[:stamp] } if live.nil?

    render partial: "runs/status", locals: { run: live, log: live_log }
  end

  # Returns you to wherever you pressed Stop, since the button appears on the
  # index and the new-test page as well as the run's own page.
  def cancel
    client.cancel(params[:stamp])
    redirect_back fallback_location: run_path(params[:stamp]), notice: "Load test stopped."
  rescue Harness::Client::Error => e
    redirect_back fallback_location: run_path(params[:stamp]), alert: e.message
  end

  # Ships a finished run's results into this dashboard.
  #
  # Delegated to the runner rather than imported directly: the results are CSV
  # on the runner's disk, and this app is not necessarily on that machine. Runs
  # publish themselves on completion, so this is the retry path.
  def publish
    client.publish(params[:stamp])
    redirect_to run_path(params[:stamp]),
      notice: "Publishing results — the dashboard will update shortly."
  rescue Harness::Client::Error => e
    redirect_to run_path(params[:stamp]), alert: e.message
  end

  # Feeds this run's charts, from whichever source has them.
  #
  # One endpoint and one shape for both, because it is the runner's own payload
  # either way: served live while the run is in flight, stored at import
  # afterwards. The chart cannot tell the difference, which is the point — see
  # RunProgress.
  def progress
    response.headers["Cache-Control"] = "no-store"
    stored = Run.find_by(stamp: params[:stamp])&.progress

    if stored
      # Nothing more is coming. The chart holds its line a fraction of a second
      # behind the newest point so it has something to reveal at frame rate;
      # told the run is over, it closes that gap and finishes where the data
      # does.
      render json: stored.payload.merge("running" => false)
      return
    end

    data = client.progress(params[:stamp])

    # Neither stored nor live: a run imported before the runner wrote its
    # payload, whose page says so in words rather than drawing an empty frame.
    return head :not_found if data.nil?

    render json: data.merge("running" => live_run&.dig("state") == "running")
  end

  def compare
    @runs = Run.newest_first.includes(:level_stats).limit(2).to_a

    if @runs.length < 2
      redirect_to runs_path, alert: "Need at least two runs to compare."
      return
    end

    # Newest is first per scope, so b is newest, a is previous
    @newest = @runs.first
    @previous = @runs.second
  end

  def archive
    manifest = ReadoutArchiver.cold_archive!
    redirect_to runs_path, notice: "Archived #{manifest[:run_count]} runs to #{File.basename(manifest[:dump_path])} — live DB is now empty."
  rescue ReadoutArchiver::ArchiveError => e
    redirect_to runs_path, alert: e.message
  end

  def restore
    manifest = ReadoutArchiver.restore_latest!
    redirect_to runs_path, notice: "Restored #{manifest[:run_count]} runs from #{File.basename(manifest[:dump_path])}."
  rescue ReadoutArchiver::ArchiveError => e
    redirect_to runs_path, alert: e.message
  end

  # Rescans the campfire-stress results directory and imports anything new,
  # re-importing existing runs in place so an analyzer change is picked up.
  def import
    root = Rails.configuration.x.campfire_stress.results_root

    if root.blank? || !Dir.exist?(root)
      redirect_to runs_path, alert: "Results directory not found: #{root}"
      return
    end

    runs = Analysis::Importer.import_all(root)
    redirect_to runs_path, notice: "Imported #{runs.length} #{'run'.pluralize(runs.length)}."
  rescue Analysis::Importer::MissingMetrics => e
    redirect_to runs_path, alert: e.message
  end

  private

  def client
    @client ||= Harness::Client.new
  end

  # What the runner knows about this run, or nil.
  #
  # Fails soft in every direction. An imported run has to open on an instance
  # that has no runner at all, and a runner that is down must not take the
  # dashboard's read-only half with it.
  def live_run
    @live_run ||= client.run(params[:stamp])
  rescue Harness::Client::Error
    nil
  end

  def live_log
    client.log(params[:stamp])
  rescue Harness::Client::Error
    nil
  end
end
