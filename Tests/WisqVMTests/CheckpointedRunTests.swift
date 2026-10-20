import Foundation
import XCTest

@testable import WisqVM

/// La sauvegarde continue : quand elle tombe, quand elle ne tombe pas, et ce
/// qu'un arrêt lui fait.
final class CheckpointedRunTests: XCTestCase {
    /// Une machine qui ne fait que compter. Chaque tranche retire `work`
    /// instructions et rend `.stopped`, comme une tranche épuisée ; après
    /// `slicesBeforePowerOff` tranches, elle s'éteint.
    private final class CountingMachine: GuestMachine, @unchecked Sendable {
        let work: UInt64
        let slicesBeforePowerOff: Int
        private(set) var slices = 0
        private(set) var retiredInstructions: UInt64 = 0
        private(set) var flushes = 0
        /// Ce que valait le compteur de vidages à chaque instantané.
        private(set) var flushesAtSnapshot: [Int] = []
        private let lock = NSLock()
        private var stopped = false
        /// Appelé à chaque tranche, sur le fil d'émulation.
        var onSlice: (Int) -> Void = { _ in }

        init(work: UInt64, slicesBeforePowerOff: Int = .max) {
            self.work = work
            self.slicesBeforePowerOff = slicesBeforePowerOff
        }

        var ramSizeBytes: Int { 0 }
        var diskBytesWritten: Int { 0 }
        var diskActivity: (served: UInt64, refused: UInt64)? { nil }
        func load(kernelImage: Data, commandLine: String?, initialRamdisk: Data?) throws {}
        func attachDisk(_ image: Data) throws {}
        func attachDisk(fileAt base: URL, writes: URL) throws {}
        func flushDisk() { flushes += 1 }
        func send(_ data: Data) {}
        func restore(_ data: Data) throws {}

        func runGuest(instructionBudget: UInt64) -> GuestOutcome {
            lock.lock()
            let halt = stopped
            lock.unlock()
            if halt { return .stopped }
            slices += 1
            onSlice(slices)
            retiredInstructions &+= work
            return slices >= slicesBeforePowerOff ? .powerOff : .stopped
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        func snapshot() -> Data {
            flushesAtSnapshot.append(flushes)
            return withUnsafeBytes(of: retiredInstructions) { Data($0) }
        }
    }

    /// Ce qui s'est passé, dans l'ordre, depuis plusieurs fils.
    private final class Journal: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String] = []
        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return written
        }
        @Sendable func note(_ event: String) {
            lock.lock()
            written.append(event)
            lock.unlock()
        }
    }

    /// Les sauvegardes reçues, depuis le fil d'émulation.
    private final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var saved: [Data] = []
        var all: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return saved
        }
        func append(_ data: Data) {
            lock.lock()
            saved.append(data)
            lock.unlock()
        }
    }

    /// Une horloge qui avance d'un pas à chaque lecture.
    private final class SteppingClock: @unchecked Sendable {
        private var now = Date(timeIntervalSince1970: 0)
        let step: TimeInterval
        init(step: TimeInterval) { self.step = step }
        @Sendable func read() -> Date {
            now = now.addingTimeInterval(step)
            return now
        }
    }

    /// Une machine qui travaille est sauvée à intervalle, et la fin de la
    /// course rend ce que la machine a rendu.
    func testABusyMachineIsSavedEveryInterval() {
        let machine = CountingMachine(work: 1_000, slicesBeforePowerOff: 20)
        // Une minute par lecture : `run` lit l'horloge au départ, puis après
        // chaque tranche, puis après chaque sauvegarde.
        let clock = SteppingClock(step: 60)
        let box = Saved()
        let run = CheckpointedRun(machine: machine, interval: 300, minimumWork: 1_000,
                                  clock: clock.read, pack: { $0 }, perform: { $0() }, write: { box.append($0) })
        XCTAssertEqual(run.run(), .powerOff)
        XCTAssertEqual(machine.slices, 20)
        let saved = box.all
        XCTAssertEqual(run.checkpoints, saved.count)
        XCTAssertEqual(saved.count, 3, "une sauvegarde toutes les cinq lectures, sur vingt tranches")
        // La dernière porte l'état d'alors, pas celui du départ.
        let last = saved.last.map { $0.withUnsafeBytes { $0.load(as: UInt64.self) } }
        XCTAssertEqual(last, 15_000)
    }

    /// **Une machine qui dort n'est pas réécrite.** L'intervalle passe, mais
    /// rien n'a été retiré : la sauvegarde d'avant vaut celle-ci.
    func testAnIdleMachineIsNotRewritten() {
        let machine = CountingMachine(work: 10, slicesBeforePowerOff: 50)
        let clock = SteppingClock(step: 600)
        let box = Saved()
        let run = CheckpointedRun(machine: machine, interval: 300, minimumWork: 1_000_000,
                                  clock: clock.read, pack: { $0 }, perform: { $0() }, write: { box.append($0) })
        XCTAssertEqual(run.run(), .powerOff)
        XCTAssertEqual(box.all.count, 0)
    }

    /// Le disque est scellé **avant** chaque instantané.
    func testTheDiskIsFlushedBeforeEachSnapshot() {
        let machine = CountingMachine(work: 1, slicesBeforePowerOff: 10)
        let clock = SteppingClock(step: 1_000)
        let run = CheckpointedRun(machine: machine, interval: 1, minimumWork: 1,
                                  clock: clock.read, pack: { $0 }, perform: { $0() }, write: { _ in })
        _ = run.run()
        XCTAssertFalse(machine.flushesAtSnapshot.isEmpty)
        for (index, flushes) in machine.flushesAtSnapshot.enumerated() {
            XCTAssertEqual(flushes, index + 1, "le vidage d'abord, puis l'instantané")
        }
    }

    /// Une sauvegarde qui échoue ne fait pas tomber la machine.
    func testAFailedSaveLeavesTheMachineRunning() {
        struct Full: Error {}
        let machine = CountingMachine(work: 1, slicesBeforePowerOff: 10)
        let clock = SteppingClock(step: 1_000)
        let run = CheckpointedRun(machine: machine, interval: 1, minimumWork: 1,
                                  clock: clock.read, pack: { $0 }, perform: { $0() }, write: { _ in throw Full() })
        XCTAssertEqual(run.run(), .powerOff)
        XCTAssertEqual(machine.slices, 10)
        XCTAssertEqual(run.checkpoints, 0)
    }

    /// **Un arrêt est un arrêt** : la course rend `.stopped`, et une tranche
    /// épuisée n'en est pas un.
    func testStopEndsTheRunButAnExhaustedSliceDoesNot() {
        let machine = CountingMachine(work: 1)
        let clock = SteppingClock(step: 1)
        let run = CheckpointedRun(machine: machine, interval: 1_000_000, minimumWork: .max,
                                  clock: clock.read, pack: { $0 }, perform: { $0() }, write: { _ in })
        machine.onSlice = { slices in if slices == 7 { run.stop() } }
        XCTAssertEqual(run.run(), .stopped)
        XCTAssertEqual(machine.slices, 7, "les six tranches épuisées avant l'arrêt ont continué")
    }

    /// **`stop` attend l'écriture en cours.** Sinon « Arrêter » effacerait
    /// l'instantané, puis l'écriture finissante le ferait revenir, et la
    /// machine arrêtée reviendrait au lancement suivant.
    func testStopWaitsForASaveInFlight() throws {
        let machine = CountingMachine(work: 1)
        let clock = SteppingClock(step: 1_000)
        let saving = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let journal = Journal()
        let note = journal.note
        let run = CheckpointedRun(machine: machine, interval: 1, minimumWork: 1,
                                  clock: clock.read, pack: { $0 }, write: { _ in
                                      // Seule la première attend : le verrou
                                      // n'est pas équitable, et une seconde
                                      // sauvegarde peut passer avant `stop`.
                                      if journal.events.isEmpty {
                                          saving.signal()
                                          release.wait()
                                      }
                                      note("sauvegarde finie")
                                  })
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            _ = run.run()
            finished.signal()
        }
        thread.start()
        saving.wait()
        let stopper = Thread {
            run.stop()
            note("stop rendu")
        }
        stopper.start()
        // Laisser à `stop` le temps de buter sur le verrou.
        Thread.sleep(forTimeInterval: 0.2)
        note("sauvegarde relâchée")
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        // Le fil d'arrêt peut finir juste après la course.
        for _ in 0..<50 where journal.events.last != "stop rendu" { Thread.sleep(forTimeInterval: 0.02) }
        let events = journal.events
        XCTAssertEqual(events.first, "sauvegarde relâchée")
        XCTAssertEqual(events.dropFirst().first, "sauvegarde finie", "stop a attendu la fin de l'écriture")
        XCTAssertEqual(events.last, "stop rendu", "aucune sauvegarde après l'arrêt")
        XCTAssertEqual(events.filter { $0 == "stop rendu" }.count, 1)
    }

    /// **Une compression en cours n'est pas attendue : elle est jetée.**
    /// `stop` rend la main tout de suite, et ce qui était en train d'être
    /// compressé n'est jamais écrit — l'écrire après un « Arrêter » ferait
    /// revenir la machine.
    func testAStopDuringCompressionDiscardsTheSave() {
        let machine = CountingMachine(work: 1)
        let clock = SteppingClock(step: 1_000)
        let packing = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let box = Saved()
        let run = CheckpointedRun(machine: machine, interval: 1, minimumWork: 1,
                                  clock: clock.read, pack: { snapshot in
                                      packing.signal()
                                      release.wait()
                                      return snapshot
                                  }, write: { box.append($0) })
        let finished = DispatchSemaphore(value: 0)
        Thread {
            _ = run.run()
            finished.signal()
        }.start()
        packing.wait()
        let stoppedAt = Date()
        run.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 0.5, "stop n'attend pas la compression")
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        release.signal()
        // Laisser à la compression le temps de finir, puis de ne rien écrire.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(box.all.count, 0)
        XCTAssertEqual(run.checkpoints, 0)
    }
}
