import os

enum Log {
  static let app = Logger(subsystem: "dev.nedlane.Islet", category: "app")
  static let media = Logger(subsystem: "dev.nedlane.Islet", category: "media")
  static let shell = Logger(subsystem: "dev.nedlane.Islet", category: "shell")
}
