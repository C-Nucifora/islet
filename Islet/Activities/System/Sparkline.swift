import SwiftUI

/// How a series maps onto the sparkline's vertical extent.
enum SparklineScale: Equatable, Sendable {
  /// A known range — CPU, GPU and memory are all fractions of 1.
  case fixed(min: Double, max: Double)
  /// Stretch to the window's own extremes. Disk and network throughput have no ceiling, so the
  /// only useful reference is the last 60 samples.
  case auto
}

/// Normalises a series into the unit square: x runs 0 (oldest) to 1 (newest), y runs 0 (bottom)
/// to 1 (top). Empty input yields no points; a single sample yields a flat two-point line, since
/// one reading describes a level and not a slope.
func sparklinePoints(_ values: [Double], scale: SparklineScale) -> [CGPoint] {
  guard !values.isEmpty else { return [] }

  let lo: Double
  let hi: Double
  switch scale {
  case .fixed(let min, let max):
    lo = min
    hi = max
  case .auto:
    lo = values.min() ?? 0
    hi = values.max() ?? 0
  }
  let span = hi - lo

  func normalise(_ value: Double) -> Double {
    // A collapsed range has no meaningful shape; mid-height reads as "flat", which is the truth.
    guard span > 0 else { return 0.5 }
    return Swift.min(Swift.max((value - lo) / span, 0), 1)
  }

  guard values.count > 1 else {
    let y = normalise(values[0])
    return [CGPoint(x: 0, y: y), CGPoint(x: 1, y: y)]
  }

  let step = 1.0 / Double(values.count - 1)
  return values.enumerated().map { CGPoint(x: Double($0.offset) * step, y: normalise($0.element)) }
}

/// One chart point with its time-derived horizontal position. `startsSegment` prevents the shape
/// from joining readings separated by a long sleep or stalled run loop.
struct TimedSparklinePoint: Equatable {
  let point: CGPoint
  let startsSegment: Bool
}

/// Selects real measurements at roughly even time positions. It never averages or interpolates
/// a value, so lowering the render budget cannot fabricate a measurement that never happened.
func downsampleMetricSamples(
  _ samples: [TimedMetricSample], maximumCount: Int
) -> [TimedMetricSample] {
  downsampleMetricSampleIndices(samples, maximumCount: maximumCount).map { samples[$0] }
}

private func downsampleMetricSampleIndices(
  _ samples: [TimedMetricSample], maximumCount: Int
) -> [Int] {
  let limit = max(1, maximumCount)
  guard samples.count > limit else { return Array(samples.indices) }
  guard limit > 1, let first = samples.first, let last = samples.last else {
    return samples.indices.last.map { [$0] } ?? []
  }

  let start = first.timestamp.timeIntervalSinceReferenceDate
  let duration = last.timestamp.timeIntervalSinceReferenceDate - start
  guard duration > 0 else {
    return Array(samples.indices.suffix(limit))
  }

  var result = [samples.startIndex]
  var nextIndex = 1
  for position in 1..<(limit - 1) {
    let target = start + duration * Double(position) / Double(limit - 1)
    while nextIndex < samples.count - 1,
      samples[nextIndex].timestamp.timeIntervalSinceReferenceDate < target
    {
      nextIndex += 1
    }
    if result.last != nextIndex {
      result.append(nextIndex)
    }
  }
  if result.last != samples.index(before: samples.endIndex) {
    result.append(samples.index(before: samples.endIndex))
  }
  return result
}

/// Normalises timestamped samples into a fixed wall-clock chart window. The x coordinate is the
/// time since `now - timeWindow`, not the sample's position in an array. That keeps a five-minute
/// chart five minutes wide whether monitoring ran at 1 Hz, 20 seconds, or 30 seconds.
func timedSparklinePoints(
  _ samples: [TimedMetricSample], now: Date, timeWindow: TimeInterval,
  maximumContiguousGap: TimeInterval, maximumCount: Int, scale: SparklineScale
) -> [TimedSparklinePoint] {
  let window = max(0, timeWindow)
  let lowerBound = now.addingTimeInterval(-window)
  let visible = samples.filter { $0.timestamp >= lowerBound && $0.timestamp <= now }
  guard !visible.isEmpty else { return [] }

  let renderedIndices = downsampleMetricSampleIndices(visible, maximumCount: maximumCount)
  let values = visible.map(\.value)
  let lo: Double
  let hi: Double
  switch scale {
  case .fixed(let min, let max):
    lo = min
    hi = max
  case .auto:
    lo = values.min() ?? 0
    hi = values.max() ?? 0
  }
  let verticalSpan = hi - lo

  func normalise(_ value: Double) -> Double {
    guard verticalSpan > 0 else { return 0.5 }
    return Swift.min(Swift.max((value - lo) / verticalSpan, 0), 1)
  }

  var previousIndex: Int?
  let points = renderedIndices.map { index in
    let sample = visible[index]
    let elapsed = sample.timestamp.timeIntervalSince(lowerBound)
    let x = window > 0 ? Swift.min(Swift.max(elapsed / window, 0), 1) : 1
    let startsSegment: Bool
    if let previousIndex {
      var previousTimestamp = visible[previousIndex].timestamp
      startsSegment = ((previousIndex + 1)...index).contains { sourceIndex in
        defer { previousTimestamp = visible[sourceIndex].timestamp }
        return visible[sourceIndex].timestamp.timeIntervalSince(previousTimestamp)
          > maximumContiguousGap
      }
    } else {
      startsSegment = true
    }
    defer { previousIndex = index }
    return TimedSparklinePoint(
      point: CGPoint(x: x, y: normalise(sample.value)),
      startsSegment: startsSegment)
  }
  guard points.count == 1, let point = points.first?.point else { return points }

  // A move-only path is invisible. Show one real reading as a short flat segment centred on its
  // timestamp instead of stretching it across unmeasured time or inventing another value.
  let halfWidth = 0.02
  let startX = max(0, point.x - halfWidth)
  let endX = min(1, point.x + halfWidth)
  return [
    TimedSparklinePoint(point: CGPoint(x: startX, y: point.y), startsSegment: true),
    TimedSparklinePoint(point: CGPoint(x: endX, y: point.y), startsSegment: false),
  ]
}

/// Draws a normalised series. Unit space is y-up; the SwiftUI rect is y-down, so y is flipped here.
struct Sparkline: Shape {
  let values: [Double]
  let scale: SparklineScale

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let points = sparklinePoints(values, scale: scale)
    guard points.count >= 2 else { return path }
    for (index, point) in points.enumerated() {
      let mapped = CGPoint(
        x: rect.minX + point.x * rect.width,
        y: rect.maxY - point.y * rect.height)
      if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
    }
    return path
  }
}

/// Draws timestamped points without stretching unevenly sampled history to fill the width.
struct TimedSparkline: Shape {
  let samples: [TimedMetricSample]
  let now: Date
  let scale: SparklineScale
  let timeWindow: TimeInterval
  let maximumContiguousGap: TimeInterval
  let maximumCount: Int

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let points = timedSparklinePoints(
      samples, now: now, timeWindow: timeWindow,
      maximumContiguousGap: maximumContiguousGap, maximumCount: maximumCount, scale: scale)
    guard !points.isEmpty else { return path }

    for (index, timedPoint) in points.enumerated() {
      let point = timedPoint.point
      let mapped = CGPoint(
        x: rect.minX + point.x * rect.width,
        y: rect.maxY - point.y * rect.height)
      if index == 0 || timedPoint.startsSegment {
        path.move(to: mapped)
      } else {
        path.addLine(to: mapped)
      }
    }
    return path
  }
}

/// The sparkline as it appears in a metric row: 28 × 14 pt over a faint plate.
struct SparklineView: View {
  let history: MetricRing
  let scale: SparklineScale

  private var referenceDate: Date { history.latestTimestamp ?? Date() }

  var body: some View {
    TimedSparkline(
      samples: history.samples, now: referenceDate, scale: scale,
      timeWindow: history.timeWindow, maximumContiguousGap: history.maximumContiguousGap,
      maximumCount: SystemChartHistory.maximumRenderedSamples
    )
    .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    .padding(.vertical, 1)
    .frame(width: 28, height: 14)
    .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06)))
    // The number beside it already carries the value; a path of 60 points is noise to VoiceOver.
    .accessibilityHidden(true)
  }
}
