import Foundation
// Compiled only into the test executable, never into LocalVoice.app.
enum AppPaths { static let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVoice-test-unused") }
