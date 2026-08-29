import os

enum Log {
  static let app = Logger(subsystem: "dev.islet", category: "app")
  static let media = Logger(subsystem: "dev.islet", category: "media")
  static let shell = Logger(subsystem: "dev.islet", category: "shell")
}
