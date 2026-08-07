# Shared by the controllers that drive the local runner service.
#
# Launching a load test and switching which server it measures are both only
# meaningful where a runner is actually reachable — the deployed instance has
# neither k6 nor the machine under test — so both are gated the same way rather
# than each deciding for itself.
module RunnerAccess
  extend ActiveSupport::Concern

  included do
    before_action :require_runner
  end

  private

  def client
    @client ||= Harness::Client.new
  end

  def require_runner
    return if client.available?

    redirect_to runs_path,
      alert: "No runner is reachable. Load tests are launched from the machine " \
             "running the harness — start it with `bin/runner` in campfire-stress."
  end
end
