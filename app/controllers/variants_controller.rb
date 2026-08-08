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
    render partial: "variants/variant", locals: variant_locals(error: flash[:alert])
  end

  # Redirected rather than rendered, which is not a style choice.
  #
  # This is submitted from inside a Turbo Frame, and rendering the frame in
  # response to the POST left the frame's src pointing at this URL — which
  # accepts no GET. The next poll fetched it, got a 404, and the frame said
  # "Content missing" the moment the switch finished. Redirecting sends the
  # frame back to a URL it can keep asking for.
  #
  # The refusal survives the redirect because the frame renders the flash
  # itself. It is only lost when a redirect lands somewhere the flash is drawn
  # outside the frame, which is what made rendering look necessary.
  def switch
    client.switch_variant(params[:name])
    redirect_to variant_path, status: :see_other
  rescue Harness::Client::Busy => e
    redirect_to variant_path, status: :see_other, alert: e.message
  rescue Harness::Client::Error => e
    redirect_to variant_path, status: :see_other, alert: "Could not switch: #{e.message}"
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
