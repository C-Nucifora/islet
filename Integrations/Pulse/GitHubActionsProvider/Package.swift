// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "IsletGitHubActionsProvider",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "islet-github-actions", targets: ["IsletGitHubActions"])
  ],
  targets: [
    .target(name: "GitHubActionsProviderCore"),
    .executableTarget(
      name: "IsletGitHubActions", dependencies: ["GitHubActionsProviderCore"]),
    .testTarget(
      name: "GitHubActionsProviderCoreTests",
      dependencies: ["GitHubActionsProviderCore"],
      resources: [.copy("Fixtures")]),
  ]
)
