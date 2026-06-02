import Combine
import Foundation

@MainActor
final class SSHSessionStore: ObservableObject {
    private var sessions: [HostRecord.ID: PTYSession] = [:]
    private var sessionObservers: [HostRecord.ID: AnyCancellable] = [:]

    func session(for host: HostRecord) -> PTYSession {
        if let session = sessions[host.id] {
            return session
        }

        let session = PTYSession()
        session.prepare(host: host)
        sessions[host.id] = session
        observe(session, for: host.id)
        return session
    }

    func prepare(host: HostRecord) {
        session(for: host).prepare(host: host)
    }

    func start(host: HostRecord) {
        session(for: host).start(host: host)
    }

    func stop(hostID: HostRecord.ID) {
        sessions[hostID]?.stop()
    }

    func closeSession(for hostID: HostRecord.ID) {
        sessions.removeValue(forKey: hostID)?.stop()
        sessionObservers[hostID] = nil
    }

    func isHostRunning(_ hostID: HostRecord.ID) -> Bool {
        sessions[hostID]?.isRunning ?? false
    }

    private func observe(_ session: PTYSession, for hostID: HostRecord.ID) {
        sessionObservers[hostID] = session.$state.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }
}
