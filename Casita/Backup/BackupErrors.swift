import Foundation

func backupErrorMessage(_ error: any Error) -> String {
    switch error {
    case BackupError.notBackupFile: return "That file isn't a Casita backup."
    case BackupError.corrupt: return "This backup is damaged or incomplete. Download it again or choose another copy."
    case BackupError.wrongRecoveryKey: return "This sentence doesn't open this backup."
    case BackupError.iCloudUnavailable: return "iCloud Drive isn't available. Sign in to iCloud and enable iCloud Drive, then try again."
    default:
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
            return "There isn't enough free space on this iPhone. Free some space and try again."
        }
        return "Couldn't access the backup. Check your connection and that the file has downloaded, then try again."
    }
}
