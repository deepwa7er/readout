# Which build of Campfire the next load test will measure.
#
# Switching is deliberately its own action rather than a field on the launch
# form. A switch redeploys and restarts the application under test, so it starts
# with an empty page cache: the sequence that produces comparable numbers is
# switch, discard a warm-up run, then start the run you intend to keep. A launch
# that silently restarted the server would make that impossible to get right.
class VariantsController < ApplicationController
  include RunnerAccess

  # The frame's contents. Polled while a switch is in progress, which is why it
  # is a fragment rather than a page.
  def show
    render partial: "variants/variant", locals: variant_locals
  end

  def switch
    client.switch_variant(params[:name])

    # Rendered rather than redirected, on purpose. This is submitted from inside
    # a Turbo Frame, and a redirect would have its matching frame extracted and
    # the flash dropped on the floor — so a refusal would vanish silently. The
    # frame carries its own outcome instead.
    render partial: "variants/variant", locals: variant_locals
  rescue Harness::Client::Busy => e
    render partial: "variants/variant", locals: variant_locals(error: e.message)
  rescue Harness::Client::Error => e
    render partial: "variants/variant", locals: variant_locals(error: "Could not switch: #{e.message}")
  end

  private

  # A runner that cannot be reached mid-page must not blank the frame: the page
  # says what it could not read rather than implying there are no variants.
  def variant_locals(error: nil)
    { data: client.variants || {}, error: error }
  rescue Harness::Client::Error => e
    { data: {}, error: error || "Could not read the deployed server: #{e.message}" }
  end
end
