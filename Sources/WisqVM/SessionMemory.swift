import Foundation

/// **La mémoire d'une machine qu'on reprend est celle de sa session.**
///
/// Une machine se construit à la taille réglée, rognée sur ce que l'appareil a
/// de libre au moment du démarrage (`KernelMemory.size`). Un instantané, lui,
/// porte la mémoire de la machine qui l'a écrit, et une machine d'une autre
/// taille le refuse (`Snapshot.Failure.ramSizeMismatch`).
///
/// L'application prenait ce refus pour « pas de session » : elle démarrait le
/// noyau à neuf, et la sauvegarde continue écrasait l'instantané quelques
/// minutes plus tard. Il suffisait que le téléphone ait moins de mémoire libre
/// qu'au moment de la sauvegarde — un jeu ouvert à côté —, ou que la personne
/// ait déplacé le réglage, pour que la session soit perdue sans un mot.
///
/// La règle : **une session lisible impose sa taille**. Si elle tient dans ce
/// que l'appareil a de libre, la machine est construite à cette taille-là ;
/// sinon le démarrage est refusé, et l'instantané gardé tel quel pour plus
/// tard. Le réglage ne sert qu'aux démarrages à neuf.
public enum SessionMemory {
    public enum Choice: Equatable, Sendable {
        /// Pas de session lisible : la taille calculée depuis le réglage.
        case boot(Int)
        /// La session, à la taille où elle a été sauvée.
        case resume(Int)
        /// La session ne tient pas dans ce qui est libre maintenant.
        case tooLittleRoom(saved: Int, room: Int)
    }

    /// La taille qu'un instantané demande, lue par le cœur qui l'a écrit.
    public static func savedRAMSize(_ saved: Data, core: GuestArchitecture.Core) -> Int? {
        switch core {
        case .riscv32: return LinuxMachine.savedRAMSize(in: saved)
        case .x86_64: return X86Machine.savedRAMSize(in: saved)
        }
    }

    /// `fresh` est la taille d'un démarrage à neuf, planchers compris ;
    /// `saved`, ce que l'instantané demande, s'il y en a un de lisible.
    public static func choose(fresh: Int, saved: Int?, room: Int) -> Choice {
        guard let saved, saved > 0 else { return .boot(fresh) }
        return saved <= room ? .resume(saved) : .tooLittleRoom(saved: saved, room: room)
    }

    /// Ce que la personne lit quand sa session ne tient pas.
    public static func explanation(saved: Int, room: Int, name: String) -> String {
        """
        La session de \(name) a été sauvée avec \(saved >> 20) Mo de mémoire, \
        et cet appareil n'en a que \(room >> 20) Mo de libre en ce moment.

        Elle est gardée telle quelle. Fermez ce qui tourne à côté et réessayez.
        """
    }
}
