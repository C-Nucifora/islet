import Defaults
import SwiftUI

enum AppTheme: String, CaseIterable, Codable, Identifiable, Sendable {
  case classic
  case mono
  case ocean
  case violet
  case sunset
  case forest
  case catppuccin

  var id: Self { self }

  var title: String {
    switch self {
    case .classic: "Classic"
    case .mono: "Mono"
    case .ocean: "Ocean"
    case .violet: "Violet"
    case .sunset: "Sunset"
    case .forest: "Forest"
    case .catppuccin: "Catppuccin"
    }
  }

  var accentColor: Color { color(for: .interaction) }

  /// Settings uses the system window background instead of the island's black surface. Keep the
  /// Mono palette adaptive there so controls never render white on a light background.
  func settingsAccentColor(for colorScheme: ColorScheme) -> Color {
    guard self == .mono else { return accentColor }
    return colorScheme == .light ? .black : .white
  }

  /// Foreground content drawn on top of the Settings accent, such as navigation glyphs.
  func settingsAccentForegroundColor(for colorScheme: ColorScheme) -> Color {
    guard self == .mono else { return .white }
    return colorScheme == .light ? .white : .black
  }

  func powerFlowColor(for role: BatteryFlowRole) -> Color {
    switch (self, role) {
    case (.mono, _): .white

    case (.classic, .externalPower), (.classic, .batteryCharge): .green
    case (.classic, .batterySupplement): .orange
    case (.classic, .systemLoad): .cyan
    case (.classic, .usbOutput): .purple

    case (.ocean, .externalPower), (.ocean, .batteryCharge): .cyan
    case (.ocean, .batterySupplement): .blue
    case (.ocean, .systemLoad): .teal
    case (.ocean, .usbOutput): .indigo

    case (.violet, .externalPower), (.violet, .batteryCharge):
      Color(red: 0.72, green: 0.48, blue: 1)
    case (.violet, .batterySupplement): .pink
    case (.violet, .systemLoad): .purple
    case (.violet, .usbOutput): .indigo

    case (.sunset, .externalPower), (.sunset, .batteryCharge): .yellow
    case (.sunset, .batterySupplement): .orange
    case (.sunset, .systemLoad): .pink
    case (.sunset, .usbOutput): Color(red: 1, green: 0.38, blue: 0.25)

    case (.forest, .externalPower), (.forest, .batteryCharge): .green
    case (.forest, .batterySupplement): .mint
    case (.forest, .systemLoad): .teal
    case (.forest, .usbOutput): .yellow

    case (.catppuccin, .externalPower), (.catppuccin, .batteryCharge):
      Color(red: 0.65, green: 0.89, blue: 0.63)
    case (.catppuccin, .batterySupplement): Color(red: 0.98, green: 0.70, blue: 0.53)
    case (.catppuccin, .systemLoad): Color(red: 0.45, green: 0.78, blue: 0.93)
    case (.catppuccin, .usbOutput): Color(red: 0.80, green: 0.65, blue: 0.97)
    }
  }

  func color(for role: AppThemeRole) -> Color {
    switch (self, role) {
    case (.classic, .interaction): .blue
    case (.classic, .calendar), (.classic, .reminders), (.classic, .system),
      (.classic, .timer):
      .orange
    case (.classic, .clipboard): .purple
    case (.classic, .ports), (.classic, .pulse): .cyan
    case (.classic, .shelf), (.classic, .continuity): .blue
    case (.classic, .nowPlaying), (.classic, .t3Code): .green
    case (.classic, .battery): .white

    case (.mono, .interaction), (.mono, .calendar), (.mono, .timer), (.mono, .battery),
      (.mono, .nowPlaying), (.mono, .t3Code):
      .white
    case (.mono, .clipboard), (.mono, .shelf), (.mono, .continuity): Color(white: 0.82)
    case (.mono, .ports), (.mono, .system), (.mono, .reminders), (.mono, .pulse):
      Color(white: 0.68)

    case (.ocean, .interaction), (.ocean, .shelf), (.ocean, .continuity), (.ocean, .t3Code):
      .blue
    case (.ocean, .calendar), (.ocean, .system), (.ocean, .timer), (.ocean, .battery),
      (.ocean, .pulse):
      .cyan
    case (.ocean, .clipboard): .indigo
    case (.ocean, .ports), (.ocean, .reminders), (.ocean, .nowPlaying): .teal

    case (.violet, .interaction), (.violet, .clipboard), (.violet, .nowPlaying),
      (.violet, .t3Code):
      .purple
    case (.violet, .calendar), (.violet, .reminders), (.violet, .pulse): .pink
    case (.violet, .ports), (.violet, .shelf), (.violet, .continuity): .indigo
    case (.violet, .system), (.violet, .timer), (.violet, .battery):
      Color(red: 0.72, green: 0.48, blue: 1)

    case (.sunset, .interaction), (.sunset, .calendar), (.sunset, .timer), (.sunset, .battery),
      (.sunset, .nowPlaying), (.sunset, .t3Code):
      .orange
    case (.sunset, .clipboard), (.sunset, .reminders), (.sunset, .pulse): .pink
    case (.sunset, .ports): .yellow
    case (.sunset, .shelf), (.sunset, .system), (.sunset, .continuity):
      Color(red: 1, green: 0.38, blue: 0.25)

    case (.forest, .interaction), (.forest, .calendar), (.forest, .timer), (.forest, .battery),
      (.forest, .nowPlaying), (.forest, .t3Code):
      .green
    case (.forest, .clipboard), (.forest, .shelf), (.forest, .continuity): .mint
    case (.forest, .ports), (.forest, .system), (.forest, .reminders), (.forest, .pulse):
      .teal

    // Catppuccin Mocha accents: mauve, pink, sapphire, teal, peach, green and blue.
    case (.catppuccin, .interaction), (.catppuccin, .clipboard), (.catppuccin, .t3Code):
      Color(red: 0.80, green: 0.65, blue: 0.97)
    case (.catppuccin, .calendar), (.catppuccin, .reminders):
      Color(red: 0.96, green: 0.76, blue: 0.91)
    case (.catppuccin, .ports): Color(red: 0.58, green: 0.89, blue: 0.84)
    case (.catppuccin, .shelf), (.catppuccin, .continuity):
      Color(red: 0.54, green: 0.71, blue: 0.98)
    case (.catppuccin, .system), (.catppuccin, .pulse):
      Color(red: 0.45, green: 0.78, blue: 0.93)
    case (.catppuccin, .timer), (.catppuccin, .battery):
      Color(red: 0.98, green: 0.70, blue: 0.53)
    case (.catppuccin, .nowPlaying): Color(red: 0.65, green: 0.89, blue: 0.63)
    }
  }
}

extension AppTheme: Defaults.Serializable {}

enum BatteryGraphStyle: String, CaseIterable, Codable, Identifiable, Sendable {
  case coloured
  case monochrome

  var id: Self { self }

  var title: String {
    switch self {
    case .coloured: "Coloured"
    case .monochrome: "Monochrome"
    }
  }
}

extension BatteryGraphStyle: Defaults.Serializable {}

enum BatteryFlowRole: Sendable {
  case externalPower
  case batterySupplement
  case systemLoad
  case usbOutput
  case batteryCharge
}

enum AppThemeRole: CaseIterable, Hashable, Sendable {
  case interaction
  case battery
  case calendar
  case clipboard
  case continuity
  case nowPlaying
  case ports
  case pulse
  case reminders
  case shelf
  case system
  case t3Code
  case timer
}

private struct AppThemeEnvironmentKey: EnvironmentKey {
  static let defaultValue = AppTheme.classic
}

private struct BatteryGraphStyleEnvironmentKey: EnvironmentKey {
  static let defaultValue = BatteryGraphStyle.coloured
}

extension EnvironmentValues {
  var appTheme: AppTheme {
    get { self[AppThemeEnvironmentKey.self] }
    set { self[AppThemeEnvironmentKey.self] = newValue }
  }

  var batteryGraphStyle: BatteryGraphStyle {
    get { self[BatteryGraphStyleEnvironmentKey.self] }
    set { self[BatteryGraphStyleEnvironmentKey.self] = newValue }
  }
}

private struct AppThemeForegroundModifier: ViewModifier {
  @Environment(\.appTheme) private var theme
  let role: AppThemeRole

  func body(content: Content) -> some View {
    content.foregroundStyle(theme.color(for: role))
  }
}

extension View {
  func appThemeForeground(_ role: AppThemeRole) -> some View {
    modifier(AppThemeForegroundModifier(role: role))
  }
}
