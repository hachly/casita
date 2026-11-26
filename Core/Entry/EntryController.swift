import Foundation

/// What the entry screen needs from whoever owns the storage: the app's
/// `AppModel` or the share extension's model.
@MainActor
protocol EntryController: AnyObject, Observable {
    var checking: Bool { get }
    var waits: WrongCodeWaits { get }
    var hideDotsLine: Bool { get }
    var haptics: Bool { get }
    /// Returns false for a wrong code or during a wait. Takes at least the
    /// storage's minimum unlock duration.
    func submit(code: String) async -> Bool
    func unlockWithFaceID() async -> FaceIDResult
    /// Erases Casita and returns to first run. The way back when the top
    /// space was deleted and no code opens anything. The extension can't.
    func startOver()
    /// The app offers "Forgot code?" (reset with the words, or start over);
    /// the extension doesn't. The same on every space either way.
    var offersForgotCode: Bool { get }
    func forgotCode()
    /// "Still remember your code?" now and then, nil most of the time. Any
    /// code that opens a space answers it.
    var reminder: String? { get }
}

extension EntryController {
    func startOver() {}
    var offersForgotCode: Bool { false }
    func forgotCode() {}
    var reminder: String? { nil }
}

enum FaceIDResult { case opened, notSetUp, failed }
