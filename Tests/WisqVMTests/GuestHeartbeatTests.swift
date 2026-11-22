import XCTest

@testable import WisqVM

/// **La phrase qui dit si la machine avance encore.**
///
/// Elle existe parce qu'une capture d'écran a montré un noyau qui imprime
/// quelques lignes puis n'écrit plus rien pendant dix minutes, sans que rien
/// ne dise s'il tournait toujours. Ces tests tiennent les deux verdicts qu'elle
/// doit savoir rendre, et surtout le second : dire « figée » quand ça l'est.
final class GuestHeartbeatTests: XCTestCase {
    private func at(_ retired: UInt64, _ rip: UInt64 = 0x1000) -> GuestProgress {
        GuestProgress(retired: retired, rip: rip)
    }

    /// Une machine qui avance dit à quelle vitesse.
    func testAMovingMachineSaysHowFast() {
        let line = GuestHeartbeat.line(
            now: at(12_000_000), since: at(2_000_000), seconds: 1)
        XCTAssertTrue(line.contains("MIPS"), line)
        XCTAssertTrue(line.contains("10,0 MIPS"), line)
        XCTAssertFalse(line.contains("figée"), line)
    }

    /// **Et une machine qui n'avance plus le dit, avec l'adresse.**
    ///
    /// C'est le verdict qui manquait. Sans lui, un invité bloqué et un invité
    /// lent se ressemblent — et ils ne se corrigent pas du tout pareil.
    /// L'adresse est la moitié qui permet d'agir : la retrouver dans le noyau
    /// nomme la fonction qui tourne en rond.
    func testAStoppedMachineSaysSoAndNamesTheAddress() {
        let line = GuestHeartbeat.line(
            now: at(3_000_000_000, 0xffff_ffff_810b_2c40),
            since: at(3_000_000_000, 0xffff_ffff_810b_2c40),
            seconds: 5)
        XCTAssertTrue(line.contains("figée depuis 5 s"), line)
        XCTAssertTrue(line.contains("0xffffffff810b2c40"), line)
    }

    /// **Un seul intervalle vide ne suffit pas à crier au blocage.** Le fil
    /// publie sur la cadence de vidage de la console, pas à la milliseconde :
    /// un intervalle peut tomber entre deux publications sans que rien n'aille
    /// mal, et une alerte qui clignote ne veut plus rien dire.
    func testOneQuietIntervalIsNotAStall() {
        let line = GuestHeartbeat.line(
            now: at(5_000_000), since: at(5_000_000), seconds: 0.5)
        XCTAssertFalse(line.contains("figée"), line)
    }

    /// Sans relevé précédent, la vitesse est **inconnue** — pas nulle. Un
    /// « 0 MIPS » au premier tour se lirait « à l'arrêt » sur une machine qui
    /// vient de démarrer.
    func testTheFirstReadingClaimsNoSpeed() {
        let line = GuestHeartbeat.line(now: at(400_000), since: nil, seconds: 0)
        XCTAssertFalse(line.contains("MIPS"), line)
        XCTAssertFalse(line.contains("figée"), line)
        XCTAssertTrue(line.contains("400000 instructions"), line)
    }

    /// Les grands nombres se lisent, et s'accordent.
    func testLargeCountsAreReadable() {
        XCTAssertEqual(GuestHeartbeat.instructions(0), "aucune instruction")
        XCTAssertEqual(GuestHeartbeat.instructions(1), "1 instruction")
        XCTAssertEqual(GuestHeartbeat.instructions(4_200_000), "4,2 millions d'instructions")
        // Singulier à un milliard, pluriel au-delà : « 1,0 milliards » se voit.
        XCTAssertEqual(GuestHeartbeat.instructions(1_000_000_000), "1,0 milliard d'instructions")
        XCTAssertEqual(GuestHeartbeat.instructions(3_200_000_000), "3,2 milliards d'instructions")
    }

    /// **Une machine qui tourne donne aussi son adresse.**
    ///
    /// C'est le défaut que la deuxième capture de Maxime a montré : le noyau
    /// avançait — 1,9 milliard d'instructions, 21,4 MIPS — et l'écran ne
    /// bougeait plus depuis 1,58 milliard d'instructions. « Lent » et « en
    /// rond » se ressemblaient exactement, et l'adresse, la seule chose qui
    /// les sépare, n'était donnée **que** quand le compteur était figé —
    /// c'est-à-dire dans le cas où elle sert le moins.
    func testAMovingMachineAlsoGivesItsAddress() {
        let line = GuestHeartbeat.line(
            now: at(12_000_000, 0xffff_ffff_810b_2c40),
            since: at(2_000_000, 0xffff_ffff_8100_0000),
            seconds: 1)
        XCTAssertTrue(line.contains("0xffffffff810b2c40"), line)
        XCTAssertTrue(line.contains("MIPS"), line)
    }

    /// **Deux relevés dans la même page, ça s'appelle une boucle.**
    ///
    /// Une seconde à vingt millions d'instructions sans quitter quatre kibis
    /// d'adresses veut dire au plus un millier d'instructions distinctes,
    /// chacune répétée des milliers de fois. La machine peut le dire
    /// elle-même, plutôt que de demander de comparer deux captures d'écran.
    func testTwoReadingsInOnePageAreCalledALoop() {
        let line = GuestHeartbeat.line(
            now: at(30_000_000, 0xffff_ffff_810b_2c40),
            since: at(10_000_000, 0xffff_ffff_810b_2d90),
            seconds: 1)
        XCTAssertTrue(line.contains("en rond"), line)
        XCTAssertTrue(line.contains("0xffffffff810b2c40"), line)
    }

    /// **Un invité qui calcule dans une fonction n'est pas « en rond ».**
    ///
    /// La capture qui l'a appris : « 6,7 milliards d'instructions · 402,3
    /// MIPS · en rond autour de 0xffffffff9c990e5d ». L'adresse est
    /// `lzma_main` du noyau de l'image d'installation d'Arch, qui déballait
    /// son initramfs ; il lui restait deux milliards et demi d'instructions,
    /// et la personne a lu un blocage. Les deux relevés tombent dans la même
    /// page, mais trois publications sur quatre seulement entre les deux
    /// (`wisq-pc` en mesure 69 à 80 % pendant ce déballage) : la phrase
    /// donne l'adresse et se tait.
    func testAGuestComputingInOneFunctionIsNotALoop() {
        let line = GuestHeartbeat.line(
            now: GuestProgress(retired: 6_700_000_000, rip: 0xffff_ffff_9c99_0e5d,
                               slices: 33_500, slicesOnSamePage: 25_000),
            since: GuestProgress(retired: 6_300_000_000, rip: 0xffff_ffff_9c99_08aa,
                                 slices: 31_500, slicesOnSamePage: 23_500),
            seconds: 1)
        XCTAssertFalse(line.contains("en rond"), line)
        XCTAssertTrue(line.contains("0xffffffff9c990e5d"), line)
        XCTAssertTrue(line.contains("400,0 MIPS"), line)
    }

    /// **Et une vraie boucle le reste** : quatre-vingt-dix-huit publications
    /// sur cent dans la même page, la part d'un noyau en panique qui attend
    /// dans `delay_tsc`.
    func testAGuestThatNeverLeavesItsPageIsStillALoop() {
        let line = GuestHeartbeat.line(
            now: GuestProgress(retired: 30_000_000, rip: 0xffff_ffff_825c_c30d,
                               slices: 200, slicesOnSamePage: 197),
            since: GuestProgress(retired: 10_000_000, rip: 0xffff_ffff_825c_c2f7,
                                 slices: 100, slicesOnSamePage: 99),
            seconds: 1)
        XCTAssertTrue(line.contains("en rond autour de 0xffffffff825cc30d"), line)
    }

    /// **Trop peu de publications pour juger** : les deux relevés décident
    /// seuls, comme pour un cœur qui ne les compte pas.
    func testTooFewSlicesLeaveTheTwoReadingsToDecide() {
        let line = GuestHeartbeat.line(
            now: GuestProgress(retired: 30_000_000, rip: 0xffff_ffff_810b_2c40,
                               slices: 110, slicesOnSamePage: 50),
            since: GuestProgress(retired: 10_000_000, rip: 0xffff_ffff_810b_2d90,
                                 slices: 100, slicesOnSamePage: 50),
            seconds: 1)
        XCTAssertTrue(line.contains("en rond"), line)
    }

    /// **Et l'inverse ne se déduit pas.** Deux adresses éloignées ne prouvent
    /// pas que le noyau avance : il peut tourner dans une boucle plus large
    /// qu'une page. La phrase donne donc l'adresse et se tait sur le reste —
    /// affirmer « ça avance » serait exactement le bouchon complaisant que ce
    /// dépôt s'interdit.
    func testDistantAddressesClaimNoProgress() {
        let line = GuestHeartbeat.line(
            now: at(30_000_000, 0xffff_ffff_8200_0000),
            since: at(10_000_000, 0xffff_ffff_8100_0000),
            seconds: 1)
        XCTAssertFalse(line.contains("en rond"), line)
        XCTAssertFalse(line.contains("avance"), line)
        XCTAssertTrue(line.contains("0xffffffff82000000"), line)
    }

    /// **Un intervalle où rien n'a tourné n'est pas une boucle.**
    ///
    /// Ce test manquait, et un sabotage l'a montré en survivant : retirer la
    /// garde « quelque chose a tourné » ne cassait rien. Sans elle, un
    /// intervalle vide — le fil publie sur la cadence de vidage, pas à la
    /// milliseconde — se lirait « en rond », parce que l'adresse n'a pas bougé.
    /// Elle n'a pas bougé parce qu'aucune instruction n'a été retirée : c'est
    /// une absence de relevé, pas une boucle. Les nommer pareil ferait dire à
    /// la phrase une chose qu'elle n'a pas mesurée.
    func testAnIntervalWithNoWorkIsNotALoop() {
        let line = GuestHeartbeat.line(
            now: at(5_000_000, 0xffff_ffff_810b_2c40),
            since: at(5_000_000, 0xffff_ffff_810b_2c40),
            seconds: 0.5)
        XCTAssertFalse(line.contains("en rond"), line)
        XCTAssertFalse(line.contains("figée"), line)
    }

    /// **Une vitesse sous le million ne s'arrondit pas à zéro.** « 0 MIPS » se
    /// lirait « à l'arrêt » sur une machine qui tourne, ce qui est l'exacte
    /// confusion que tout ceci existe pour lever.
    func testASlowMachineIsNotRoundedToZero() {
        let line = GuestHeartbeat.line(now: at(300_000), since: at(0), seconds: 1)
        XCTAssertFalse(line.contains("0,0 MIPS"), line)
        XCTAssertTrue(line.contains("300 mille instructions par seconde"), line)
    }

    /// **Une console muette pendant que l'invité avance, dite en premier.**
    ///
    /// La capture d'Arch : « 4,7 milliards d'instructions · 405,6… », coupée
    /// là par la largeur du téléphone, pendant que le noyau décodait son
    /// initramfs sans rien écrire. Le silence passe maintenant devant, là où
    /// un écran étroit le montre.
    func testAQuietGuestThatComputesSaysSoFirst() {
        let now = GuestProgress(retired: 4_700_000_000, rip: 0xffff_ffff_9c99_0e5d,
                                slices: 23_500, slicesOnSamePage: 17_000)
        let since = GuestProgress(retired: 4_294_400_000, rip: 0xffff_ffff_9c99_08aa,
                                  slices: 21_472, slicesOnSamePage: 15_500)
        let quiet = GuestHeartbeat.line(now: now, since: since, seconds: 1, silentFor: 25)
        XCTAssertTrue(quiet.hasPrefix("silencieuse depuis 25 s, elle calcule · 405,6 MIPS"), quiet)
        XCTAssertTrue(quiet.contains("0xffffffff9c990e5d"), quiet)

        let long = GuestHeartbeat.line(now: now, since: since, seconds: 1, silentFor: 185)
        XCTAssertTrue(long.hasPrefix("silencieuse depuis 3 min 05 s"), long)

        // Sous le seuil, la ligne d'avant.
        let talking = GuestHeartbeat.line(now: now, since: since, seconds: 1, silentFor: 9)
        XCTAssertFalse(talking.contains("silencieuse"), talking)
        XCTAssertTrue(talking.hasPrefix("4,7 milliards"), talking)
    }

    /// Le silence ne couvre ni un blocage ni une boucle : ceux-là ont leur
    /// phrase, et elle est plus utile.
    func testSilenceDoesNotHideAStallOrALoop() {
        let stalled = GuestHeartbeat.line(now: at(5_000), since: at(5_000), seconds: 3, silentFor: 60)
        XCTAssertTrue(stalled.contains("figée"), stalled)
        XCTAssertFalse(stalled.contains("silencieuse"), stalled)

        let loop = GuestHeartbeat.line(
            now: GuestProgress(retired: 2_000_000_000, rip: 0x1010, slices: 200, slicesOnSamePage: 196),
            since: GuestProgress(retired: 1_000_000_000, rip: 0x1000, slices: 100, slicesOnSamePage: 98),
            seconds: 1, silentFor: 60)
        XCTAssertTrue(loop.contains("en rond"), loop)
        XCTAssertFalse(loop.contains("silencieuse"), loop)
    }
}
