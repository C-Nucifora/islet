import SwiftUI

/// The notch outline: flat top, top corners flare OUTWARD into the menu bar,
/// bottom corners round inward. SwiftUI coords (origin top-left).
struct NotchShape: Shape {
  var topRadius: CGFloat
  var bottomRadius: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(topRadius, bottomRadius) }
    set {
      topRadius = newValue.first
      bottomRadius = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    // top-left outward flare
    p.addQuadCurve(
      to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
      control: CGPoint(x: rect.minX + topRadius, y: rect.minY))
    // left side down
    p.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
    // bottom-left inward corner
    p.addQuadCurve(
      to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
      control: CGPoint(x: rect.minX + topRadius, y: rect.maxY))
    // bottom edge
    p.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
    // bottom-right inward corner
    p.addQuadCurve(
      to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
      control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY))
    // right side up
    p.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
    // top-right outward flare
    p.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY),
      control: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
    p.closeSubpath()
    return p
  }
}

#Preview("Expanded") {
  NotchShape(topRadius: 19, bottomRadius: 24)
    .fill(.black)
    .frame(width: 640, height: 190)
    .padding()
}
