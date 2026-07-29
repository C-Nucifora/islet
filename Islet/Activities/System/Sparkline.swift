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

/// The sparkline as it appears in a metric row: 28 × 14 pt over a faint plate.
struct SparklineView: View {
  let values: [Double]
  let scale: SparklineScale

  var body: some View {
    Sparkline(values: values, scale: scale)
      .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
      .padding(.vertical, 1)
      .frame(width: 28, height: 14)
      .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.06)))
      // The number beside it already carries the value; a path of 60 points is noise to VoiceOver.
      .accessibilityHidden(true)
  }
}
