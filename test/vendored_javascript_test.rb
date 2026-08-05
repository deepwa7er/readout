require "test_helper"

# Guards against a failure that is invisible from the server.
#
# `bin/importmap pin <package>` downloads whatever the CDN serves, and popular
# packages ship code-split ESM builds: the vendored file imports
# "./chunks/something.js" or "../_/<hash>.js", and importmap does not fetch those
# chunks. Every check that can be made server-side still passes — the pin exists,
# the asset is served with a 200, the page references it — and the module then
# fails to resolve in the browser, so the feature silently never works.
#
# Chart.js was vendored here for exactly one release and hit exactly this. It has
# since been dropped (the live chart draws itself on a canvas; the static charts
# are server-rendered SVG), so there may be nothing vendored at all — which is
# fine. This exists so the next dependency is checked automatically.
class VendoredJavascriptTest < ActiveSupport::TestCase
  IMPORT_PATTERN = /(?:^|\s)(?:import|export)\s*(?:\{[^}]*\}|\*|\w+)?\s*from\s*['"]([^'"]+)['"]/

  test "vendored javascript, if any, has no unresolved module specifiers" do
    files = Dir[Rails.root.join("vendor/javascript/**/*.js")]

    files.each do |path|
      specifiers = File.read(path).scan(IMPORT_PATTERN).flatten.uniq

      assert_empty specifiers,
        "#{File.basename(path)} imports #{specifiers.inspect}, which importmap will not " \
        "resolve in the browser. Vendor a self-contained bundle instead."
    end
  end

  # Anything a controller imports must actually be pinned, or the module fails to
  # load and the controller never runs.
  test "controller imports resolve to something the importmap knows about" do
    pinned = File.read(Rails.root.join("config/importmap.rb"))
      .scan(/^\s*pin\s+["']([^"']+)["']/).flatten
    pinned << "controllers" # pin_all_from covers the controllers directory

    Dir[Rails.root.join("app/javascript/controllers/*.js")].each do |path|
      File.read(path).scan(/from\s+["']([^"'.][^"']*)["']/).flatten.each do |specifier|
        next if specifier.start_with?("controllers/")

        assert pinned.any? { |p| specifier == p || specifier.start_with?("#{p}/") },
          "#{File.basename(path)} imports #{specifier.inspect}, which is not pinned in " \
          "config/importmap.rb — it will fail to load in the browser."
      end
    end
  end
end
