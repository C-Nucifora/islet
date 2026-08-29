import Defaults
import XCTest

@testable import Islet

final class AppThemeTests: XCTestCase {
  func testThemesHaveStableNamesAndOrder() {
    XCTAssertEqual(
      AppTheme.allCases.map(\.rawValue),
      ["classic", "mono", "ocean", "violet", "sunset", "forest", "catppuccin"])
    XCTAssertEqual(
      AppTheme.allCases.map(\.title),
      ["Classic", "Mono", "Ocean", "Violet", "Sunset", "Forest", "Catppuccin"])
  }

  func testThemePreferenceRoundTripsEveryTheme() {
    let saved = Defaults[.appTheme]
    defer { Defaults[.appTheme] = saved }

    for theme in AppTheme.allCases {
      Defaults[.appTheme] = theme
      XCTAssertEqual(Defaults[.appTheme], theme)
    }
  }

  func testBatteryGraphStylesHaveStableNamesAndRoundTrip() {
    XCTAssertEqual(BatteryGraphStyle.allCases.map(\.rawValue), ["coloured", "monochrome"])
    XCTAssertEqual(BatteryGraphStyle.allCases.map(\.title), ["Coloured", "Monochrome"])

    let saved = Defaults[.batteryGraphStyle]
    defer { Defaults[.batteryGraphStyle] = saved }

    for style in BatteryGraphStyle.allCases {
      Defaults[.batteryGraphStyle] = style
      XCTAssertEqual(Defaults[.batteryGraphStyle], style)
    }
  }
}
