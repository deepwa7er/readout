require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Readout
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Where the campfire-stress harness writes its results. Overridable so the
    # dashboard can read a copy of the results from somewhere else without
    # touching code.
    config.x.campfire_stress.results_root =
      ENV.fetch("CAMPFIRE_STRESS_RESULTS", File.expand_path("~/code/campfire-stress/results"))

    # The local runner service, which launches load tests on the machine that has
    # k6 and writes results where this app can import them.
    #
    # The deployed instance has no runner and must never appear to offer one:
    # launching is only meaningful where the harness actually lives. Presence is
    # probed at request time rather than assumed from the environment.
    config.x.runner.url = ENV.fetch("RUNNER_URL", "http://127.0.0.1:7881")
    config.x.runner.token_file =
      ENV.fetch("RUNNER_TOKEN_FILE", File.expand_path("~/code/campfire-stress/.runner-token"))
  end
end
