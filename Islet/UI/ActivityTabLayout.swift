import CoreGraphics

/// Pure layout policy for the expanded activity switcher.
///
/// The first id is Home. Every tab remains visible when the strip has room. A control slot is
/// reserved for More only when the screen-width limit forces an overflow. A selection made from
/// More is promoted into the last visible slot so its selected state is never hidden.
enum ActivityTabLayout {
  static let controlWidth: CGFloat = 20
  static let spacing: CGFloat = 4
  static let horizontalPadding: CGFloat = 12

  struct Result: Equatable {
    let visibleIDs: [String]
    let overflowIDs: [String]
  }

  static func split(tabIDs: [String], selectedID: String, controlCapacity: Int) -> Result {
    guard !tabIDs.isEmpty else { return Result(visibleIDs: [], overflowIDs: []) }

    let capacity = max(2, controlCapacity)
    let visibleCount = tabIDs.count <= capacity ? tabIDs.count : capacity - 1

    var visible = Array(tabIDs.prefix(visibleCount))
    if !visible.contains(selectedID), tabIDs.contains(selectedID), visible.count > 1 {
      visible[visible.count - 1] = selectedID
    }
    let visibleSet = Set(visible)
    return Result(
      visibleIDs: visible,
      overflowIDs: tabIDs.filter { !visibleSet.contains($0) })
  }

  /// Width available before the centered physical notch begins. `spacing` is removed because the
  /// outer HStack inserts that gap between this strip and the flexible notch spacer.
  static func leftStripWidth(
    containerWidth: CGFloat, horizontalPadding: CGFloat, notchWidth: CGFloat, spacing: CGFloat,
    minimum: CGFloat
  ) -> CGFloat {
    let usable = max(0, containerWidth - horizontalPadding * 2)
    let leftEar = max(0, (usable - notchWidth) / 2)
    return max(minimum, leftEar - spacing)
  }

  static func controlCapacity(width: CGFloat, controlWidth: CGFloat, spacing: CGFloat) -> Int {
    guard controlWidth > 0, width > 0 else { return 2 }
    return max(2, Int((width + spacing) / (controlWidth + spacing)))
  }

  /// Container width that gives every tab a control in the left ear. Expansion stays symmetric
  /// around the physical notch and clamps only when the panel would reach the screen edge.
  static func preferredContainerWidth(
    tabCount: Int, notchWidth: CGFloat, minimumWidth: CGFloat, maximumWidth: CGFloat,
    horizontalPadding: CGFloat = ActivityTabLayout.horizontalPadding,
    controlWidth: CGFloat = ActivityTabLayout.controlWidth,
    spacing: CGFloat = ActivityTabLayout.spacing
  ) -> CGFloat {
    let count = max(1, tabCount)
    let controls = CGFloat(count) * controlWidth + CGFloat(count - 1) * spacing
    let required = notchWidth + horizontalPadding * 2 + (controls + spacing) * 2
    let upperBound = max(minimumWidth, maximumWidth)
    return min(upperBound, max(minimumWidth, ceil(required)))
  }
}
