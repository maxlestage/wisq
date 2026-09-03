import Foundation
import XCTest

@testable import WisqCore

/// A VM this build does not understand used to cost the whole list.
///
/// `AgentVM` had **no tests at all**, and `listVMs` decodes `[AgentVM]` in one
/// call. So one machine reporting a state, a protocol or a guest OS this build
/// had never heard of did not cost that machine — it emptied the list.
///
/// The scenario is this project's own distribution model rather than a
/// hypothetical: the daemon is installed by Homebrew or a `curl` script and
/// updated independently of the sideloaded app. `brew upgrade` on the host, no
/// update on the phone, and "my VMs" goes blank.
///
/// Third time this exact shape has turned up — after `Settings` and
/// `MachineStore`. A habit rather than an accident, which is why the two edges
/// below are spelled out again: what falls back, and what must not.
final class AgentVMToleranceTests: XCTestCase {
    private func vm(_ json: String) throws -> AgentVM {
        try JSONDecoder().decode(AgentVM.self, from: Data(json.utf8))
    }

    private func list(_ json: String) throws -> [AgentVM] {
        try JSONDecoder().decode([AgentVM].self, from: Data(json.utf8))
    }

    // MARK: - What a newer agent may report

    /// The enum already had `.unknown`; the decoder simply never reached for it.
    func testAStateThisBuildDoesNotKnowBecomesUnknown() throws {
        XCTAssertEqual(try vm(#"{"id":"a","name":"n","state":"migrating"}"#).state, .unknown)
    }

    /// Found by probe rather than predicted: an **absent** state threw too.
    func testAnAbsentStateBecomesUnknownRatherThanThrowing() throws {
        XCTAssertEqual(try vm(#"{"id":"a","name":"n"}"#).state, .unknown)
    }

    func testAGuestOSThisBuildDoesNotKnowBecomesUnknown() throws {
        XCTAssertEqual(try vm(#"{"id":"a","name":"n","state":"running","guestOS":"plan9"}"#).guestOS, .unknown)
    }

    /// The consequence that made this worth fixing.
    func testOneUnreadableVMNoLongerEmptiesTheList() throws {
        let vms = try list(
            #"[{"id":"a","name":"bonne","state":"running"},"#
                + #"{"id":"b","name":"future","state":"migrating"}]"#)
        XCTAssertEqual(vms.map(\.name), ["bonne", "future"])
        XCTAssertEqual(vms.last?.state, .unknown)
    }

    // MARK: - The edge that must not fall back

    /// `consoleProtocol` decides what wisq speaks to the port the agent
    /// published. An unrecognised name becomes nil — "no console I know how to
    /// open" — and never `.vnc`, which would open a VNC session against
    /// something else entirely. Same asymmetry as `Machine.security`.
    func testAnUnknownConsoleProtocolBecomesNilRatherThanADefault() throws {
        let decoded = try vm(
            #"{"id":"a","name":"n","state":"running","consoleProtocol":"wayland","consolePort":5900}"#)
        XCTAssertNil(decoded.consoleProtocol, "un protocole inconnu ne doit pas devenir VNC")
        XCTAssertEqual(decoded.consolePort, 5900, "et le reste de la VM survit quand même")
    }

    /// And the VM is still listed: a console wisq cannot open is a VM the user
    /// may still want to see, and to start or stop.
    func testAVMWithAnUnopenableConsoleIsStillListed() throws {
        let vms = try list(
            #"[{"id":"a","name":"exotique","state":"running","consoleProtocol":"wayland"}]"#)
        XCTAssertEqual(vms.map(\.name), ["exotique"])
    }

    // MARK: - What must not change

    /// Every name this build knows still means itself. A fallback wide enough
    /// to swallow the unknown must not swallow the known — the half that makes
    /// the rest safe.
    func testEveryKnownNameStillMeansItself() throws {
        for state in [AgentVM.State.running, .paused, .stopped, .starting, .unknown] {
            XCTAssertEqual(try vm(#"{"id":"a","name":"n","state":"\#(state.rawValue)"}"#).state, state)
        }
        for proto in RemoteProtocol.allCases {
            XCTAssertEqual(
                try vm(#"{"id":"a","name":"n","state":"running","consoleProtocol":"\#(proto.rawValue)"}"#)
                    .consoleProtocol, proto)
        }
        for guest in GuestOS.allCases {
            XCTAssertEqual(
                try vm(#"{"id":"a","name":"n","state":"running","guestOS":"\#(guest.rawValue)"}"#).guestOS,
                guest)
        }
    }

    /// The fields that identify the VM are still required: a reply with no `id`
    /// is not a VM with a default name, it is a reply this client cannot use.
    func testAVMWithoutAnIdentityIsStillRefused() {
        XCTAssertThrowsError(try vm(#"{"name":"n","state":"running"}"#))
        XCTAssertThrowsError(try vm(#"{"id":"a","state":"running"}"#))
    }

    /// And a reply that is not a list at all still throws, rather than becoming
    /// an empty one — "you have no VMs" is a claim, and a wrong one here.
    func testAReplyThatIsNotAListStillThrows() {
        XCTAssertThrowsError(try list(#"{"vms":[]}"#))
    }

    /// A well-formed VM round-trips through encode and decode unchanged. The
    /// custom decoder is the only half that was rewritten, and this is what
    /// catches it drifting from the encoder the synthesis still provides.
    func testAFullVMSurvivesARoundTrip() throws {
        let original = AgentVM(
            id: "vm-1", name: "debian", state: .running,
            consoleProtocol: .vnc, consolePort: 5901, guestOS: .linux)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AgentVM.self, from: encoded), original)
    }
}

/// La mémoire que l'agent annonce, et ce qu'elle ne doit jamais coûter.
///
/// Deux nombres, parce que libvirt en garde deux et qu'ils répondent à des
/// questions différentes : le maximum ne peut pas changer pendant que le
/// domaine tourne, la part courante est ce qu'il a le droit d'utiliser
/// maintenant. Sur un domaine éteint, les deux viennent de sa définition.
///
/// Mesuré contre un vrai agent devant un vrai libvirt (10.0.0) : un domaine
/// éteint réglé à 128 Mio avec un maximum de 256 rend exactement
/// `{"id":"blind-vm","maximumMemoryKiB":262144,"memoryKiB":131072,…}`.
final class AgentVMMemoryTests: XCTestCase {
    private func vm(_ json: String) throws -> AgentVM {
        try JSONDecoder().decode(AgentVM.self, from: Data(json.utf8))
    }

    private func list(_ json: String) throws -> [AgentVM] {
        try JSONDecoder().decode([AgentVM].self, from: Data(json.utf8))
    }

    /// La réponse réelle de l'agent, relue telle quelle.
    func testTheTwoFiguresArriveFromARealAgentResponse() throws {
        let machine = try vm(
            #"{"id":"blind-vm","maximumMemoryKiB":262144,"memoryKiB":131072,"#
                + #""name":"blind-vm","state":"stopped"}"#)
        XCTAssertEqual(machine.memoryKiB, 131_072)
        XCTAssertEqual(machine.maximumMemoryKiB, 262_144)
    }

    /// Un agent plus ancien n'en dit rien, et ce n'est pas une panne : le
    /// démon s'installe par Homebrew et se met à jour sans le téléphone.
    func testAnOlderAgentThatSaysNothingIsNotAFailure() throws {
        let machine = try vm(#"{"id":"x","name":"x","state":"running"}"#)
        XCTAssertNil(machine.memoryKiB)
        XCTAssertNil(machine.maximumMemoryKiB)
    }

    /// Et la moitié tolérante de la même règle que l'état : la mémoire est
    /// **montrée**, jamais agie. Un agent qui l'enverrait dans une forme que
    /// cette version ne comprend pas doit coûter une ligne de texte à cette
    /// VM-là, pas la liste entière dans laquelle elle est arrivée.
    func testAMemoryInAShapeThisBuildCannotReadCostsOnlyItsOwnLine() throws {
        let machines = try list(
            #"[{"id":"a","name":"a","state":"running","memoryKiB":"beaucoup"},"#
                + #"{"id":"b","name":"b","state":"running","memoryKiB":2097152}]"#)
        XCTAssertEqual(machines.count, 2, "la liste entière ne doit pas disparaître")
        XCTAssertNil(machines[0].memoryKiB, "illisible se lit « je ne sais pas »")
        XCTAssertEqual(machines[1].memoryKiB, 2_097_152, "et la voisine est intacte")
    }

    /// Les deux nombres survivent à un aller-retour d'encodage.
    ///
    /// La comparaison porte sur eux et non sur la valeur entière, pour une
    /// raison qui vaut d'être écrite : **`AgentVM` n'est jamais encodé en
    /// production**, il n'est que décodé depuis l'agent, et son aller-retour
    /// n'est délibérément pas l'identité — un `guestOS` absent se relit
    /// `.unknown`, comme le dit la tolérance du type. Exiger l'égalité
    /// complète tiendrait donc une propriété que ce type n'a pas et n'a pas
    /// besoin d'avoir, et casserait au prochain champ ajouté.
    func testTheFiguresSurviveARoundTrip() throws {
        let original = AgentVM(
            id: "debian-13", name: "Debian 13", state: .running,
            memoryKiB: 2_097_152, maximumMemoryKiB: 4_194_304)
        let back = try JSONDecoder().decode(
            AgentVM.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(back.memoryKiB, original.memoryKiB)
        XCTAssertEqual(back.maximumMemoryKiB, original.maximumMemoryKiB)
        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.state, original.state)
    }
}

/// La mémoire d'une VM distante, telle qu'on la lit.
final class AgentVMMemoryDescriptionTests: XCTestCase {
    private func vm(_ memory: Int?, _ maximum: Int?) -> AgentVM {
        AgentVM(
            id: "x", name: "x", state: .running,
            memoryKiB: memory, maximumMemoryKiB: maximum)
    }

    /// Rien de dit, rien de montré. Un zéro se lirait « aucune mémoire ».
    func testAnAgentThatSaysNothingShowsNothing() {
        XCTAssertNil(vm(nil, nil).memoryDescription)
    }

    /// Le cas de presque toutes les machines : les deux nombres sont égaux, et
    /// la ligne n'en montre qu'un. Répéter « 256 Mio sur un maximum de 256 Mio »
    /// partout apprendrait à sauter la ligne sur la seule machine où elle dit
    /// quelque chose.
    func testEqualFiguresAreShownOnce() {
        XCTAssertEqual(vm(262_144, 262_144).memoryDescription, "256 Mio")
        XCTAssertEqual(vm(2_097_152, 2_097_152).memoryDescription, "2 Gio")
    }

    /// Et quand ils diffèrent — un domaine dont la part courante a été réglée
    /// plus bas que son maximum — les deux sont dits. Mesuré sur un vrai
    /// libvirt : c'est exactement ce que `virsh setmem --config` produit.
    func testDifferingFiguresAreBothSaid() {
        XCTAssertEqual(
            vm(131_072, 262_144).memoryDescription,
            "128 Mio sur un maximum de 256 Mio")
    }

    /// Un agent qui ne donne qu'un des deux ne fait pas disparaître la ligne.
    func testOneFigureAloneIsStillWorthShowing() {
        XCTAssertEqual(vm(nil, 262_144).memoryDescription, "256 Mio")
        XCTAssertEqual(vm(262_144, nil).memoryDescription, "256 Mio")
    }

    /// Les unités, en puissances de deux, et sans décimale quand elle serait
    /// toujours nulle — libvirt distribue des nombres ronds.
    func testSizesReadInPowersOfTwo() {
        XCTAssertEqual(AgentVM.describe(kibibytes: 512), "512 Kio")
        XCTAssertEqual(AgentVM.describe(kibibytes: 1024), "1 Mio")
        XCTAssertEqual(AgentVM.describe(kibibytes: 1_572_864), "1,5 Gio")
        XCTAssertEqual(AgentVM.describe(kibibytes: 0), "0 Kio")
    }
}
