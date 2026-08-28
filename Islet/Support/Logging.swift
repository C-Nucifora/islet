import os

enum Log {
  static let app = Logger(subsystem: "dev.cnucifora.Islet", category: "app")
  static let media = Logger(subsystem: "dev.cnucifora.Islet", category: "media")
  static let shell = Logger(subsystem: "dev.cnucifora.Islet", category: "shell")
}
