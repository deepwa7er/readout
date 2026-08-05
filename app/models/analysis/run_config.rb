# Reads the run-config.txt that bin/run.sh writes beside each set of results.
#
# A results directory that cannot be tied back to the configuration that
# produced it is not evidence of anything, so this is treated as part of the
# data rather than as decoration.
module Analysis
  class RunConfig
    KNOWN_KEYS = %w[
      stamp scenario target generator k6
      VUS USER_POOL SESSION_SECONDS RAMP_UP HOLD RAMP_DOWN
      HOT_ROOM_SHARE HOT_ROOM_ID THINK_MIN_MS THINK_MAX_MS
      W_READ_HISTORY W_SWITCH_ROOM W_POST_MESSAGE W_IDLE
    ].freeze

    # bin/run.sh writes this placeholder when a variable was left unset.
    UNSET = "<config default>"

    attr_reader :values

    def initialize(values)
      @values = values
    end

    def self.parse(path)
      return new({}) unless path && File.exist?(path)

      values = {}
      File.foreach(path) do |line|
        key, value = line.strip.split("=", 2)
        next if key.nil? || value.nil? || value.empty?

        values[key] = value
      end

      new(values)
    end

    def [](key) = @values[key]

    def scenario = @values["scenario"]
    def target = @values["target"]
    def generator = @values["generator"]
    def k6_version = @values["k6"]

    # Only the settings that were explicitly set for this run; the rest came
    # from config.js defaults and would be noise on the page.
    def explicit_settings
      @values
        .slice(*KNOWN_KEYS)
        .reject { |_, value| value == UNSET }
        .except("stamp", "scenario", "target", "generator", "k6")
    end
  end
end
