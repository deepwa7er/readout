# Streams a k6 metrics.csv into the few series we actually need.
#
# These files reach ~700k lines / 80MB, so the whole file is never held in
# memory and CSV.parse is avoided entirely. Only the first three columns are
# read (metric_name, timestamp, metric_value); all three are simple scalars that
# cannot contain a comma, so a bounded String#split is safe here in a way that
# splitting the full row would not be -- later columns hold URLs and tag lists.
module Analysis
  class MetricsFile
    Sample = Struct.new(:at, :value)

    attr_reader :vu_timeline, :latency_samples, :counter_samples

    def initialize(path)
      @path = path
      @vu_timeline = []
      @latency_samples = Hash.new { |h, k| h[k] = [] }
      @counter_samples = Hash.new { |h, k| h[k] = [] }
      @parsed = false
    end

    def self.parse(path)
      new(path).tap(&:parse)
    end

    def parse
      return self if @parsed

      wanted_latency = LATENCY_METRICS.keys.to_set
      wanted_counter = COUNTER_METRICS.to_set

      File.open(@path, "r") do |file|
        file.each_line.with_index do |line, index|
          next if index.zero? # header

          name, timestamp, value = line.split(",", 4)
          next if value.nil?

          at = Integer(timestamp, exception: false)
          number = Float(value, exception: false)
          next if at.nil? || number.nil?

          if name == "vus"
            @vu_timeline << [ at, number.to_i ]
          elsif wanted_latency.include?(name)
            @latency_samples[name] << Sample.new(at, number)
          elsif wanted_counter.include?(name)
            @counter_samples[name] << Sample.new(at, number)
          end
        end
      end

      # k6 writes samples in time order, but sorting makes the downstream
      # segment logic independent of that assumption.
      @vu_timeline.sort_by!(&:first)
      @parsed = true
      self
    end

    def empty?
      @vu_timeline.empty?
    end
  end
end
