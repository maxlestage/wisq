#if os(iOS)
import Foundation
import Network
import Observation

/// Watches the local network for `_wisq-agent._tcp` announcements so the import
/// screen can offer nearby daemons instead of making the user type an address.
@Observable
@MainActor
public final class AgentBrowser {
    public struct DiscoveredAgent: Identifiable, Hashable {
        public var id: String { name }
        public var name: String
        /// `hostname:port` once resolved; the import screen feeds it to its
        /// address field as-is.
        public var address: String
    }

    public private(set) var agents: [DiscoveredAgent] = []

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_wisq-agent._tcp", domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredAgent? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                // The daemon announces under its host name, and mDNS makes host
                // "nas" reachable at nas.local — no SRV resolution needed for a
                // default-port daemon; the pairing URL covers the rest.
                return DiscoveredAgent(name: name, address: "\(name).local")
            }
            Task { @MainActor [weak self] in
                self?.agents = found.sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
#endif
