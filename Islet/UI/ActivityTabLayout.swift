import CoreGraphics

/// Pure layout policy for the expanded activity switcher.
///
/// The first id is Home. It stays visible, no more than four priority tabs are shown, and one
/// control slot is reserved for More whenever anything overflows. A selection made from More is
/// promoted into the last visible priority slot so its selected state is never hidden.
enum ActivityTabLayout {
  struct Result: Equatable {
    let visibleIDs: [String]
    let overflowIDs: [String]
  }

  static func split(
    tabIDs: [String], selectedID: String, controlCapacity: Int, priorityLimit: Int = 4
  ) -> Result {
    guard !tabIDs.isEmpty else { return Result(visibleIDs: [], overflowIDs: []) }

    let capacity = max(2, controlCapacity)
    let boundedPriority = max(1, priorityLimit)
    let visibleCount: Int
    if tabIDs.count <= min(capacity, boundedPriority) {
      visibleCount = tabIDs.count
    } else {
      visibleCount = min(boundedPriority, capacity - 1)
    }

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
}
