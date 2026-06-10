import Foundation

struct TermuConfiguration: Codable, Equatable {
    var schemaVersion: Int = 1
    var hosts: [HostRecord] = []
    var selectedHostID: UUID?
    var terminalTheme: TerminalTheme = .dark
    var confirmBeforeDisconnectingSSHHost: Bool = true
    var confirmBeforeStoppingLocalTerminalTab: Bool = true
    var confirmBeforeClosingLocalTerminalTab: Bool = true
    var updatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case hosts
        case selectedHostID
        case terminalTheme
        case confirmBeforeDisconnectingSSHHost
        case confirmBeforeStoppingLocalTerminalTab
        case confirmBeforeClosingLocalTerminalTab
        case updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        hosts = try container.decodeIfPresent([HostRecord].self, forKey: .hosts) ?? []
        selectedHostID = try container.decodeIfPresent(UUID.self, forKey: .selectedHostID)
        terminalTheme = try container.decodeIfPresent(TerminalTheme.self, forKey: .terminalTheme) ?? .dark
        confirmBeforeDisconnectingSSHHost = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeDisconnectingSSHHost) ?? true
        confirmBeforeStoppingLocalTerminalTab = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeStoppingLocalTerminalTab) ?? true
        confirmBeforeClosingLocalTerminalTab = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeClosingLocalTerminalTab) ?? true
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

enum TerminalTheme: String, Codable, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark:
            return "Dark"
        case .light:
            return "Light"
        case .system:
            return "System"
        }
    }
}

enum HostKind: String, Codable, CaseIterable, Identifiable {
    case ssh
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh:
            return "SSH Host"
        case .local:
            return "Local"
        }
    }
}

struct HostRecord: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var kind: HostKind = .ssh
    var name: String = "New Host"
    var hostname: String = ""
    var port: Int = 22
    var username: String = NSUserName()
    var password: String = ""
    var group: String = "Personal"
    var tags: [String] = []
    var identityFile: String = ""
    var localWorkingDirectory: String = ""
    var notes: String = ""
    var lastConnectedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case hostname
        case port
        case username
        case password
        case group
        case tags
        case identityFile
        case localWorkingDirectory
        case notes
        case lastConnectedAt
    }

    init(kind: HostKind = .ssh) {
        self.kind = kind
        if kind == .local {
            name = "Local"
            group = "Local"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(HostKind.self, forKey: .kind) ?? .ssh
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "New Host"
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? NSUserName()
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? "Personal"
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        localWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .localWorkingDirectory) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .local && trimmed == "Local Terminal" {
            return "Local"
        }
        return trimmed.isEmpty ? "Untitled Host" : trimmed
    }

    var subtitle: String {
        if kind == .local {
            let directory = localWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return directory.isEmpty ? "Default shell" : directory
        }

        guard !hostname.isEmpty else { return "No hostname" }
        let userPrefix = username.isEmpty ? "" : "\(username)@"
        return "\(userPrefix)\(hostname):\(port)"
    }

    var isConnectable: Bool {
        switch kind {
        case .ssh:
            return !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .local:
            return true
        }
    }

    var localShellPath: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let shell, FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }

        return "/bin/zsh"
    }

    var localWorkingDirectoryPath: String? {
        let directory = localWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return nil }
        return (directory as NSString).expandingTildeInPath
    }

    var sshCommand: String {
        var parts = ["ssh"]
        parts.append(contentsOf: sshHostKeyOptionsForCommand)
        parts.append("-tt")

        if port != 22 {
            parts.append("-p")
            parts.append(String(port))
        }

        let trimmedIdentity = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentity.isEmpty {
            parts.append("-i")
            parts.append(trimmedIdentity.shellQuoted)
        }

        let destination = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? hostname
            : "\(username)@\(hostname)"

        parts.append(destination.shellQuoted)
        parts.append(Self.remoteLoginShellCommand.shellQuoted)
        return parts.joined(separator: " ")
    }

    var sshArguments: [String] {
        sshArguments(automatingSavedPassword: false)
    }

    func sshArguments(automatingSavedPassword: Bool) -> [String] {
        var arguments = sshHostKeyOptions
        let trimmedIdentity = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        arguments.append("-tt")

        if automatingSavedPassword {
            arguments.append(contentsOf: [
                "-o", "BatchMode=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes"
            ])

            if trimmedIdentity.isEmpty {
                arguments.append(contentsOf: [
                    "-o", "PubkeyAuthentication=no",
                    "-o", "PreferredAuthentications=password,keyboard-interactive"
                ])
            } else {
                arguments.append(contentsOf: [
                    "-o", "IdentitiesOnly=yes",
                    "-o", "PreferredAuthentications=publickey,password,keyboard-interactive"
                ])
            }
        }

        if port != 22 {
            arguments.append("-p")
            arguments.append(String(port))
        }

        if !trimmedIdentity.isEmpty {
            arguments.append("-i")
            arguments.append(trimmedIdentity)
        }

        let destination = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? hostname
            : "\(username)@\(hostname)"

        arguments.append(destination)
        arguments.append(Self.remoteLoginShellCommand)
        return arguments
    }

    private static let remoteLoginShellCommand = "/bin/sh -lc 'exec env PROMPT_EOL_MARK= \"${SHELL:-/bin/sh}\" -l'"

    private var sshHostKeyOptions: [String] {
        ["-o", "StrictHostKeyChecking=accept-new"]
    }

    private var sshHostKeyOptionsForCommand: [String] {
        sshHostKeyOptions.map(\.shellQuotedIfNeeded)
    }
}

enum CloudSyncStatus: Equatable {
    case checking
    case unavailable
    case synced(Date)
    case syncing
    case failed(String)

    var title: String {
        switch self {
        case .checking:
            return "Checking iCloud"
        case .unavailable:
            return "iCloud Unavailable"
        case .synced:
            return "Synced"
        case .syncing:
            return "Syncing"
        case .failed:
            return "Sync Failed"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            return "Looking for an iCloud account"
        case .unavailable:
            return "Sign in to iCloud and use a signed app build to sync"
        case .synced(let date):
            return "Last sync \(date.formatted(date: .omitted, time: .shortened))"
        case .syncing:
            return "Pushing host configuration"
        case .failed(let message):
            return message
        }
    }
}

extension String {
    var shellQuoted: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    var shellQuotedIfNeeded: String {
        rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? self : shellQuoted
    }
}
