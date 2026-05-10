import Foundation

extension Notification.Name {
    /// UserInfo key `"url"` contains the opened `URL` (typically a CSV from AirDrop).
    static let flashyOpenCSV = Notification.Name("flashyOpenCSV")

    /// Posted after resetting review progress so study UI can clear session-only state (e.g. undo stack).
    static let flashyProgressReset = Notification.Name("flashyProgressReset")
}
