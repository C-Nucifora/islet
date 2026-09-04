import AppKit
import Defaults
import SwiftUI
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

  func testEveryRoleChangesAcrossThemes() throws {
    for role in AppThemeRole.allCases {
      let colors = try Set(
        AppTheme.allCases.map { theme in
          let color = try XCTUnwrap(NSColor(theme.color(for: role)).usingColorSpace(.sRGB))
          return [
            color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent,
          ]
        })
      XCTAssertGreaterThan(colors.count, 1, "\(role) ignores the selected theme")
    }
  }

  func testMonoSettingsColorsAdaptToAppearance() throws {
    XCTAssertEqual(try rgba(AppTheme.mono.settingsAccentColor(for: .light)), [0, 0, 0, 1])
    XCTAssertEqual(
      try rgba(AppTheme.mono.settingsAccentForegroundColor(for: .light)), [1, 1, 1, 1])
    XCTAssertEqual(try rgba(AppTheme.mono.settingsAccentColor(for: .dark)), [1, 1, 1, 1])
    XCTAssertEqual(
      try rgba(AppTheme.mono.settingsAccentForegroundColor(for: .dark)), [0, 0, 0, 1])
  }

  func testNonMonoSettingsColorsKeepTheirThemeAccent() throws {
    for theme in AppTheme.allCases where theme != .mono {
      let accent = try rgba(theme.accentColor)
      XCTAssertEqual(try rgba(theme.settingsAccentColor(for: .light)), accent)
      XCTAssertEqual(try rgba(theme.settingsAccentColor(for: .dark)), accent)
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

  private func rgba(_ color: Color) throws -> [CGFloat] {
    let resolved = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
    return [
      resolved.redComponent, resolved.greenComponent, resolved.blueComponent,
      resolved.alphaComponent,
    ]
  }
}
