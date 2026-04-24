import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "app.sonar.ios", category: "app")
    static let audio = Logger(subsystem: "app.sonar.ios", category: "audio")
    static let transport = Logger(subsystem: "app.sonar.ios", category: "transport")
    static let distance = Logger(subsystem: "app.sonar.ios", category: "distance")
    static let ai = Logger(subsystem: "app.sonar.ios", category: "ai")
    static let airpods = Logger(subsystem: "app.sonar.ios", category: "airpods")
}
