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

  def show
    @run = Run.includes(:level_stats).find(params[:id])
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
end
