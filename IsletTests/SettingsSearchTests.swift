import XCTest

@testable import Islet

final class SettingsSearchTests: XCTestCase {
  func testEveryDetailPageMatchesAControlBelowItsPageTitle() {
    let deepQueries: [SettingsDetailPage: String] = [
      .startupDisplays: "run setup",
      .appearance: "catppuccin battery graph",
      .interaction: "collapse after",
      .energy: "automatic low power",
      .activityOrder: "file shelf",
      .calendarReminders: "calendars shown",
      .nowPlaying: "bundle identifier",
      .continuity: "keep iphone idle",
      .systemMetrics: "number bar",
      .clipboard: "concealed credential",
      .systemHUD: "test brightness",
      .eventSources: "airdrop received",
      .t3Code: "pairing keychain",
      .pulse: "clear history",
      .permissions: "location wifi names",
      .diagnostics: "open logs folder",
      .reset: "restore appearance",
    ]

    XCTAssertEqual(deepQueries.count, SettingsDetailPage.allCases.count)
    for page in SettingsDetailPage.allCases {
      let query = try! XCTUnwrap(deepQueries[page])
      XCTAssertTrue(page.matchesSearch(query), "\(page) did not match \(query)")
    }
  }

  func testSearchRequiresEveryQueryWord() {
    XCTAssertTrue(SettingsDetailPage.systemHUD.matchesSearch("brightness accessibility"))
    XCTAssertFalse(SettingsDetailPage.systemHUD.matchesSearch("brightness calendar"))
  }

  func testSearchIgnoresCaseDiacriticsAndPunctuation() {
    XCTAssertTrue(SettingsDetailPage.eventSources.matchesSearch("WI-FI"))
    XCTAssertTrue(SettingsDetailPage.eventSources.matchesSearch("wifi"))
    XCTAssertTrue(SettingsDetailPage.t3Code.matchesSearch("t3-code"))
  }

  func testBlankQueryMatches() {
    XCTAssertTrue(SettingsSearch.matches("  ", in: ["Anything"]))
  }
}
