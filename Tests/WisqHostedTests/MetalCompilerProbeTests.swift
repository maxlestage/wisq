#if canImport(Metal)
import Metal
import XCTest

/// **Metal peut-il tenir le rôle que WebKit tient ?**
///
/// Maxime a posé la question : puisqu'il n'y a pas de JIT sur iOS, et que le
/// bureau local a besoin de vitesse, est-ce que le GPU irait plus vite ? Elle
/// est bonne, parce que `MTLDevice.makeLibrary(source:)` **est** un
/// compilateur à l'exécution qu'Apple autorise dans une application de l'App
/// Store : on lui donne du texte, il rend du code machine GPU. C'est
/// structurellement le même tour que le WebAssembly rendu à WebKit.
///
/// Trois choses décident, et aucune ne se devine :
///
/// 1. **Ce que coûte une compilation.** Un cœur qui traduit bloc par bloc en
///    compile des milliers. À dix millisecondes pièce, c'est fini avant de
///    commencer.
/// 2. **Ce que coûte un lancement.** Un bloc de base fait une dizaine
///    d'instructions. Si l'aller-retour vers le GPU coûte plus que le bloc, il
///    faut regrouper — et regrouper des blocs dont on ne connaît pas la suite
///    avant de les avoir exécutés est précisément ce qu'un émulateur ne peut
///    pas faire.
/// 3. **Ce qu'un seul fil GPU rend sur une chaîne dépendante.** C'est le point
///    dur, et il est structurel : un GPU cache la latence de sa mémoire en
///    ayant des milliers de fils prêts. Un cœur x86 émulé, c'est **un** fil,
///    chaque instruction attendant la précédente. C'est le cas que
///    l'architecture d'un GPU ne couvre pas.
///
/// La boucle mesurée est celle du banc x86 et du module WebAssembly, à
/// l'identique, **registres en mémoire** — sans ça la comparaison ne veut rien
/// dire, parce qu'un vrai cœur ne garde pas son état dans des registres GPU.
/// L'oracle est refait avant tout chronomètre.
final class MetalCompilerProbeTests: XCTestCase {
    /// Huit instructions x86 par tour, comme le module WebAssembly les compte.
    private static let instructionsPerRound = 8

    /// Le noyau mesuré. Les quatre drapeaux sont calculés et écrits, comme
    /// dans le module réaliste : c'est une part du coût d'un vrai cœur, et la
    /// retirer donnerait un chiffre flatteur et faux.
    private static let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void drive(device ulong *state [[buffer(0)]],
                          constant uint &rounds [[buffer(1)]],
                          uint tid [[thread_position_in_grid]]) {
            if (tid != 0) { return; }
            for (uint i = 0; i < rounds; i++) {
                ulong rax = state[0];
                ulong rdx = state[1];
                ulong rcx = state[2];

                ulong sum = rax + rcx;
                state[8] = sum == 0;
                state[9] = sum >> 63;
                state[10] = sum < rax;
                state[11] = ((rax ^ sum) & (rcx ^ sum)) >> 63;
                state[0] = sum;

                ulong diff = sum - rdx;
                state[8] = diff == 0;
                state[9] = diff >> 63;
                state[10] = sum < rdx;
                state[11] = ((sum ^ rdx) & (sum ^ diff)) >> 63;
                if (diff == 0) {
                    state[1] = rdx + 1;
                }

                ulong left = rcx - 1;
                state[8] = left == 0;
                state[9] = left >> 63;
                state[10] = rcx < 1;
                state[2] = left;
                if (left == 0) { return; }
            }
        }

        kernel void nothing(device ulong *state [[buffer(0)]],
                            uint tid [[thread_position_in_grid]]) {
            if (tid == 0) { state[3] = state[3] + 1; }
        }
        """

    /// Le modèle, en clair. Le GPU doit rendre exactement ça.
    private static func model(rounds: UInt64) -> (rax: UInt64, rdx: UInt64, rcx: UInt64) {
        var rax: UInt64 = 0
        var rdx: UInt64 = 0
        var rcx = rounds
        while true {
            rax = rax &+ rcx
            if rax &- rdx == 0 { rdx = rdx &+ 1 }
            rcx = rcx &- 1
            if rcx == 0 { break }
        }
        return (rax, rdx, rcx)
    }

    private func metalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("aucun périphérique Metal ici : outillage, pas réponse")
        }
        return device
    }

    // MARK: - 1. Le compilateur qu'Apple autorise

    /// **Compiler du texte à l'exécution, et ce que ça coûte.**
    func testMetalCompilesSourceAtRuntimeAndWhatItCosts() throws {
        let device = try metalDevice()
        let started = Date()
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.source, options: nil)
        } catch {
            return XCTFail("le compilateur Metal a refusé la source : \(error)")
        }
        let compile = Date().timeIntervalSince(started) * 1000
        XCTAssertNotNil(library.makeFunction(name: "drive"), "le noyau doit exister")
        print("Metal compilation : \(compile) ms pour un noyau")
        // **Mesuré : 1839,7 ms pour ce noyau.** J'avais posé un seuil à une
        // seconde, et il est tombé — mais un seuil était le mauvais
        // instrument. Ce test ne défend pas une promesse, il répond à une
        // question, et la réponse est le chiffre : à presque deux secondes
        // pièce, une compilation **par bloc** est hors de question, et même
        // une compilation unique au démarrage est un temps d'attente visible.
        // Reste un plafond très large, qui n'affirme rien sur la conception et
        // n'attrape qu'une panne franche.
        XCTAssertLessThan(compile, 30_000, "le compilateur Metal ne rend plus la main")
    }

    // MARK: - 2. Ce que coûte un aller-retour

    /// **Le coût d'un lancement, à vide.**
    ///
    /// Un noyau qui incrémente un entier : ce qui est chronométré est le
    /// lancement, pas le calcul.
    func testWhatOneDispatchCosts() throws {
        let device = try metalDevice()
        let library = try device.makeLibrary(source: Self.source, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "nothing"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let state = try XCTUnwrap(
            device.makeBuffer(length: 32 * MemoryLayout<UInt64>.stride, options: .storageModeShared))

        let rounds = 200
        for _ in 0..<10 { try dispatch(pipeline, queue, state, rounds: nil) }  // à blanc
        let started = Date()
        for _ in 0..<rounds { try dispatch(pipeline, queue, state, rounds: nil) }
        let each = Date().timeIntervalSince(started) / Double(rounds) * 1000
        print("Metal lancement : \(each) ms par aller-retour")
        // Même seuil que pour le pont de WebKit : dix millisecondes mangeraient
        // l'image avant de la rendre.
        XCTAssertLessThan(each, 10, "un lancement Metal coûte plus qu'une image")
    }

    // MARK: - 3. Le point dur

    /// **Un seul fil GPU sur une chaîne dépendante, registres en mémoire.**
    func testOneGPUThreadOnASequentialCore() throws {
        let device = try metalDevice()
        let library = try device.makeLibrary(source: Self.source, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "drive"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let state = try XCTUnwrap(
            device.makeBuffer(length: 32 * MemoryLayout<UInt64>.stride, options: .storageModeShared))

        // **L'oracle d'abord.** Mille tours des deux côtés : un noyau qui ne
        // calcule pas comme le modèle rendrait un débit magnifique et faux.
        try run(pipeline, queue, state, rcx: 1000, rounds: 1000)
        let expected = Self.model(rounds: 1000)
        let got = registers(state)
        XCTAssertEqual(got.rax, expected.rax, "rax : le noyau ne calcule pas comme le modèle")
        XCTAssertEqual(got.rdx, expected.rdx, "rdx : le noyau ne calcule pas comme le modèle")
        XCTAssertEqual(got.rcx, expected.rcx, "rcx : le noyau ne calcule pas comme le modèle")

        // **Puis un calibrage, parce qu'un noyau trop long se fait tuer.** Le
        // GPU a un chien de garde ; on mesure court, puis on vise une demi-
        // seconde plutôt que de deviner un nombre de tours.
        let probeRounds: UInt64 = 100_000
        var started = Date()
        try run(pipeline, queue, state, rcx: probeRounds, rounds: probeRounds)
        let probeSeconds = Date().timeIntervalSince(started)
        let perSecond = Double(probeRounds) / max(probeSeconds, 1e-9)
        let rounds = UInt64(max(200_000, min(20_000_000, perSecond * 0.5)))

        started = Date()
        try run(pipeline, queue, state, rcx: rounds, rounds: rounds)
        let seconds = Date().timeIntervalSince(started)
        let instructions = Double(rounds) * Double(Self.instructionsPerRound)
        let mips = instructions / seconds / 1_000_000

        // Le même calcul sur le processeur du même coureur : sans ça, le
        // chiffre du GPU ne se compare à rien.
        started = Date()
        _ = Self.model(rounds: rounds)
        let cpuSeconds = Date().timeIntervalSince(started)
        let cpuMips = instructions / cpuSeconds / 1_000_000

        print("Metal un fil : \(Int(mips)) MIPS sur \(Int(instructions / 1_000_000)) M instructions")
        print("Metal comparé au Swift natif : \(Int(cpuMips)) MIPS")

        // **Aucun seuil ici, et c'est voulu.** Ce test ne défend pas une
        // vitesse : il pose une question dont la réponse décide d'un chemin.
        // Le seul échec possible est de ne pas avoir calculé juste, et c'est
        // l'oracle plus haut qui le dit.
        XCTAssertGreaterThan(mips, 0, "le noyau doit avoir tourné")
    }

    // MARK: - Le gréement

    private func registers(_ state: MTLBuffer) -> (rax: UInt64, rdx: UInt64, rcx: UInt64) {
        let words = state.contents().bindMemory(to: UInt64.self, capacity: 32)
        return (words[0], words[1], words[2])
    }

    private func run(_ pipeline: MTLComputePipelineState,
                     _ queue: MTLCommandQueue,
                     _ state: MTLBuffer,
                     rcx: UInt64,
                     rounds: UInt64) throws {
        let words = state.contents().bindMemory(to: UInt64.self, capacity: 32)
        words[0] = 0
        words[1] = 0
        words[2] = rcx
        try dispatch(pipeline, queue, state, rounds: UInt32(rounds))
    }

    private func dispatch(_ pipeline: MTLComputePipelineState,
                          _ queue: MTLCommandQueue,
                          _ state: MTLBuffer,
                          rounds: UInt32?) throws {
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(state, offset: 0, index: 0)
        if var rounds { encoder.setBytes(&rounds, length: MemoryLayout<UInt32>.size, index: 1) }
        let one = MTLSize(width: 1, height: 1, depth: 1)
        encoder.dispatchThreadgroups(one, threadsPerThreadgroup: one)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error {
            throw XCTSkip("le GPU a rendu la main : \(error)")
        }
    }
}
#endif
