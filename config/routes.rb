Rails.application.routes.draw do
  root "runs#index"

  resources :runs, only: %i[ index show ] do
    member do
      # The stored series for this run's charts. Separate from the page for the
      # same reason it is on a live run: the chart draws onto a canvas rather
      # than being re-rendered as HTML.
      get :progress
    end

    collection do
      # Rescanning the results directory is a state change, so it is a POST
      # rather than a link.
      post :import
      get :compare
      post :archive
      post :restore
    end
  end

  # Launching load tests via the local runner service. Available only where a
  # runner is reachable; the deployed instance redirects away from these.
  resources :test_runs, only: %i[ new create show ], path: "tests" do
    member do
      get :status
      # JSON for the live chart. Separate from #status on purpose: the chart
      # updates a canvas in place rather than being re-rendered as HTML, which is
      # what keeps it from flickering.
      get :progress
      post :cancel
      post :publish
    end
  end

  # Returns 200 if the app boots with no exceptions.
  get "up" => "rails/health#show", as: :rails_health_check
end
