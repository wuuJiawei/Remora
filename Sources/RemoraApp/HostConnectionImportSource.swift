import Foundation

enum HostConnectionImportSource: String, CaseIterable, Identifiable {
    case remoraJSONCSV
    case openSSH
    case windTerm
    case electerm
    case xshell
    case puTTYRegistry
    case shellSessions
    case finalShell
    case termius

    var id: String { rawValue }

    var isSupported: Bool {
        switch self {
        case .remoraJSONCSV, .openSSH, .windTerm, .electerm, .xshell, .puTTYRegistry:
            return true
        case .shellSessions, .finalShell, .termius:
            return false
        }
    }

    var title: String {
        switch self {
        case .remoraJSONCSV:
            return tr("Remora JSON / CSV")
        case .openSSH:
            return tr("OpenSSH Config")
        case .windTerm:
            return "WindTerm"
        case .electerm:
            return "electerm"
        case .xshell:
            return "Xshell"
        case .puTTYRegistry:
            return "PuTTY (.reg)"
        case .shellSessions:
            return tr("Shell Sessions")
        case .finalShell:
            return "FinalShell"
        case .termius:
            return "Termius"
        }
    }

    var detail: String {
        switch self {
        case .remoraJSONCSV:
            return tr("Import a Remora JSON or CSV file.")
        case .openSSH:
            return tr("Import hosts from ssh_config files such as ~/.ssh/config.")
        case .windTerm:
            return tr("Import SSH sessions from WindTerm user.sessions JSON.")
        case .electerm:
            return tr("Import SSH bookmarks from electerm bookmark export JSON.")
        case .xshell:
            return tr("Import sessions from Xshell .xsh files or .xts export archives.")
        case .puTTYRegistry:
            return tr("Import SSH sessions from exported PuTTY .reg files.")
        case .shellSessions:
            return tr("Planned. Local shell session import needs a dedicated local-session model.")
        case .finalShell:
            return tr("Planned. FinalShell compatibility is in development.")
        case .termius:
            return tr("Planned. Termius compatibility is in development.")
        }
    }

    var supportedFileExtensions: [String]? {
        switch self {
        case .remoraJSONCSV:
            return ["json", "csv"]
        case .openSSH:
            return nil
        case .windTerm:
            return ["json"]
        case .electerm:
            return ["json"]
        case .xshell:
            return ["xsh", "xts", "zip"]
        case .puTTYRegistry:
            return ["reg", "txt"]
        case .shellSessions, .finalShell, .termius:
            return nil
        }
    }

    var defaultDirectoryURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .openSSH:
            return home.appendingPathComponent(".ssh", isDirectory: true)
        case .windTerm:
            return home.appendingPathComponent("SSHConfig", isDirectory: true)
        case .remoraJSONCSV, .electerm, .xshell, .puTTYRegistry, .shellSessions, .finalShell, .termius:
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
    }

    static var supportedCases: [HostConnectionImportSource] {
        allCases.filter(\.isSupported)
    }

    static var upcomingCases: [HostConnectionImportSource] {
        allCases.filter { !$0.isSupported }
    }
}
