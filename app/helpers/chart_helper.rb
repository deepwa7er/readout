# Server-rendered inline SVG charts, for the STATIC charts on an imported run.
#
# The live chart during a run is Chart.js instead (see the coping_chart Stimulus
# controller), because it updates a canvas in place — a chart re-rendered as new
# HTML every two seconds flickers, and a live chart has to update constantly.
#
# These are the opposite case: they render once and never change, so a charting
# library would buy nothing. Staying in Ruby keeps them working without
# JavaScript, and their colours come from CSS custom properties via classes,
# which means light and dark mode follow for free — something a canvas cannot do
# without reading the palette back out of the stylesheet by hand.
module ChartHelper
  CHART_WIDTH = 720
  CHART_HEIGHT = 140
  PADDING_TOP = 12
  PADDING_BOTTOM = 18

  # A filled line chart over a series of [x_value, y_value] pairs.
  #
  # `threshold` draws a dashed reference line (used for full CPU saturation of
  # the host), and is skipped when it would fall outside the plotted range —
  # a reference line pinned to the top of every chart teaches the reader
  # nothing.
  def line_chart(points, threshold: nil, label: nil, y_max: nil)
    return content_tag(:p, "No samples recorded.", class: "muted") if points.blank?

    xs = points.map(&:first)
    ys = points.map(&:last)

    x_min = xs.min
    x_span = [ xs.max - x_min, 1 ].max

    # Always anchor at zero: a line chart of a rate whose baseline is hidden
    # exaggerates variation.
    top = [ y_max, ys.max, threshold ].compact.max.to_f
    top = 1.0 if top <= 0

    plot_height = CHART_HEIGHT - PADDING_TOP - PADDING_BOTTOM

    coords = points.map do |x, y|
      px = ((x - x_min).to_f / x_span) * CHART_WIDTH
      py = PADDING_TOP + plot_height - (y.to_f / top * plot_height)
      [ px.round(2), py.round(2) ]
    end

    line = coords.map { |px, py| "#{px},#{py}" }.join(" ")
    baseline = PADDING_TOP + plot_height
    area = "#{coords.first.first},#{baseline} #{line} #{coords.last.first},#{baseline}"

    tag.svg(
      class: "chart",
      viewBox: "0 0 #{CHART_WIDTH} #{CHART_HEIGHT}",
      preserveAspectRatio: "none",
      role: "img",
      "aria-label": label || "chart"
    ) do
      parts = []
      parts << tag.polygon(points: area, class: "chart-area")
      parts << tag.polyline(points: line, class: "chart-line")

      if threshold && threshold <= top
        ty = (PADDING_TOP + plot_height - (threshold.to_f / top * plot_height)).round(2)
        parts << tag.line(x1: 0, y1: ty, x2: CHART_WIDTH, y2: ty, class: "chart-threshold")
      end

      if label
        parts << tag.text(label, x: 0, y: CHART_HEIGHT - 4, class: "chart-label")
      end

      parts << tag.text(
        format_axis_value(top), x: 0, y: PADDING_TOP - 3, class: "chart-label"
      )

      safe_join(parts)
    end
  end

  # Requests per second against load, for a finished run.
  #
  # The live page charts the same measure against time; this charts it against
  # people, because for a completed run the question is "how much work could it
  # get through, and did adding people stop helping?"
  def throughput_by_load_chart(run)
    levels = run.level_stats.to_a.sort_by(&:vus).select(&:requests_per_second)
    return content_tag(:p, "Not enough data to chart.", class: "muted") if levels.empty?

    points = levels.map { |l| [ l.vus, l.requests_per_second ] }
    plotted_chart(
      points,
      y_label: "requests completed per second",
      x_label: "people using it at once"
    )
  end

  # The main chart: how slow a page got as more people used it.
  #
  # Plotted against people rather than against time, because the question is
  # "how does it behave under load", not "what happened at 14:32". Levels are
  # spaced evenly rather than by their numeric value: they are usually chosen as
  # a doubling series, and linear spacing would crush the interesting early ones
  # against the axis.
  def response_by_load_chart(run)
    levels = run.level_stats.to_a.sort_by(&:vus).select(&:room_open_p95)
    return content_tag(:p, "Not enough data to chart.", class: "muted") if levels.empty?

    points = levels.map { |l| [ l.vus, l.room_open_p95 / 1000.0 ] }
    plotted_chart(
      points,
      y_label: "seconds to open a room",
      x_label: "people using it at once",
      reference: { value: 1.0, label: "1 second" }
    )
  end

  # How hard the app worked, as a share of what it is allowed to use.
  #
  # Shown as a percentage of the app's own ceiling rather than Docker's raw
  # percent-of-one-core, which is unreadable without knowing there are six
  # workers and what a "core percent" is.
  def effort_by_load_chart(run)
    levels = run.level_stats.to_a.sort_by(&:vus).select(&:cpu_avg_pct)
    return nil if levels.empty?

    points = levels.map { |l| [ l.vus, l.cpu_avg_pct / Analysis.cpu_ceiling_pct * 100 ] }
    plotted_chart(
      points,
      y_label: "% of the server it can use",
      x_label: "people using it at once",
      reference: { value: 100.0, label: "flat out" },
      y_max: 100.0
    )
  end

  # A small labelled line chart with real axes.
  #
  # Distinct from line_chart, which is a bare sparkline for a dense time series.
  # Here there are a handful of points and each one matters, so they get drawn,
  # and both axes get ticks a reader can actually read values off.
  def plotted_chart(points, y_label:, x_label:, reference: nil, y_max: nil)
    width, height = 720, 250
    left, right, top, bottom = 52, 16, 16, 42
    plot_w = width - left - right
    plot_h = height - top - bottom

    values = points.map(&:last)
    ceiling = [ y_max, values.max, reference&.fetch(:value, nil) ].compact.max.to_f
    ceiling = 1.0 if ceiling <= 0
    # A little headroom so the peak is not welded to the top edge.
    ceiling *= 1.1 unless y_max

    x_for = ->(index) do
      return left + plot_w / 2.0 if points.length == 1
      left + (index.to_f / (points.length - 1)) * plot_w
    end
    y_for = ->(value) { top + plot_h - (value.to_f / ceiling * plot_h) }

    coords = points.each_with_index.map { |(_, value), i| [ x_for.call(i).round(2), y_for.call(value).round(2) ] }

    tag.svg(
      class: "chart chart--plotted",
      viewBox: "0 0 #{width} #{height}",
      role: "img",
      "aria-label": "#{y_label} against #{x_label}"
    ) do
      parts = []

      # Horizontal guides, faint: enough to read a value against, not enough to
      # compete with the data (the style guide's hairline rule).
      4.downto(0) do |step|
        value = ceiling * step / 4.0
        y = y_for.call(value).round(2)
        parts << tag.line(x1: left, y1: y, x2: width - right, y2: y, class: "chart-guide")
        parts << tag.text(format_tick(value), x: left - 8, y: y + 3, class: "chart-tick chart-tick--y")
      end

      if reference && reference[:value] <= ceiling
        ry = y_for.call(reference[:value]).round(2)
        parts << tag.line(x1: left, y1: ry, x2: width - right, y2: ry, class: "chart-threshold")
        parts << tag.text(reference[:label], x: width - right, y: ry - 5, class: "chart-tick chart-tick--reference")
      end

      if coords.length > 1
        parts << tag.polyline(points: coords.map { |x, y| "#{x},#{y}" }.join(" "), class: "chart-line")
      end

      coords.each_with_index do |(x, y), i|
        parts << tag.circle(cx: x, cy: y, r: 3.5, class: "chart-point")
        parts << tag.text(points[i].first.to_s, x: x, y: height - bottom + 18, class: "chart-tick chart-tick--x")
      end

      parts << tag.text(x_label, x: left + plot_w / 2.0, y: height - 6, class: "chart-axis-label chart-axis-label--x")
      parts << tag.text(y_label, x: 0, y: 0, class: "chart-axis-label",
        transform: "translate(12, #{top + plot_h / 2.0}) rotate(-90)")

      safe_join(parts)
    end
  end

  # CPU over the life of a run, with the host's full capacity marked.
  def cpu_chart(samples)
    return content_tag(:p, "No server samples recorded.", class: "muted") if samples.blank?

    origin = samples.first.at.to_i
    points = samples.filter_map do |sample|
      next if sample.cpu_pct.blank?

      [ sample.at.to_i - origin, sample.cpu_pct ]
    end

    saturation = Analysis::HOST_CORES * 100.0

    line_chart(
      points,
      threshold: saturation,
      y_max: saturation,
      label: "container cpu — dashed line is all #{Analysis::HOST_CORES} cores"
    )
  end

  # SQLite write-ahead log over the run. Growth that does not settle means
  # writes are outrunning checkpointing.
  def wal_chart(samples)
    return content_tag(:p, "No server samples recorded.", class: "muted") if samples.blank?

    origin = samples.first.at.to_i
    points = samples.filter_map do |sample|
      next if sample.wal_bytes.blank?

      [ sample.at.to_i - origin, sample.wal_bytes / 1_048_576.0 ]
    end

    line_chart(points, label: "sqlite wal — megabytes")
  end

  private

  def format_axis_value(value)
    value >= 100 ? value.round.to_s : format("%.1f", value)
  end

  # Axis ticks round to something a person would say out loud.
  def format_tick(value)
    if value >= 10
      value.round.to_s
    elsif value >= 1
      format("%.1f", value)
    elsif value.zero?
      "0"
    else
      format("%.2f", value)
    end
  end
end
