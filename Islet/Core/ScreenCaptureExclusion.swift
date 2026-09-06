import AppKit

enum ScreenCaptureExclusionStatus: Equatable {
  case active
  case unsupported
  case unverified

  var summary: String {
    switch self {
    case .active: String(localized: "Active")
    case .unsupported: String(localized: "Unsupported")
    case .unverified: String(localized: "Unverified")
    }
  }

  var detail: String {
    switch self {
    case .active:
      String(
        localized:
          "A system capture check confirmed exclusion for this session. Other capture apps may behave differently. Enabled activities keep running."
      )
    case .unsupported:
      String(
        localized:
          "Apple does not support AppKit's legacy window-sharing setting as capture protection. Islet can appear in screenshots, recordings and shared screens. Enabled activities keep running."
      )
    case .unverified:
      String(
        localized:
          "Islet asked macOS to exclude its panels, but no capture check confirmed the result. Capture apps may still show Islet. Enabled activities keep running."
      )
    }
  }
}

/// What Islet can establish about capture exclusion, rather than what AppKit accepted as a window
/// property. Reading `.none` back from `NSWindow.sharingType` only proves that AppKit stored the
/// value. It does not prove that a screenshot or recording omitted the window.
enum ScreenCaptureExclusionEvidence: Equatable {
  case captureCheckPassed
  case legacyPropertyOnly
  case unsupportedByPlatform

  var status: ScreenCaptureExclusionStatus {
    switch self {
    case .captureCheckPassed: .active
    case .legacyPropertyOnly: .unverified
    case .unsupportedByPlatform: .unsupported
    }
  }
}

struct ScreenCaptureExclusionPolicy {
  let evidence: ScreenCaptureExclusionEvidence

  /// Apple documents `NSWindow.SharingType.none` as a legacy constant that macOS no longer uses
  /// for capture protection. Islet targets macOS 26, so the current platform is unsupported.
  static let current = ScreenCaptureExclusionPolicy(evidence: .unsupportedByPlatform)

  var status: ScreenCaptureExclusionStatus { evidence.status }

  func sharingType(exclusionRequested: Bool) -> NSWindow.SharingType {
    exclusionRequested ? .none : .readOnly
  }
}
