import Foundation

/// **La phrase qui dit si la machine avance encore.**
///
/// Elle vit ici, et pas dans la vue, pour deux raisons. La première est
/// qu'elle est jugeable : ce fichier se construit sur Linux, donc l'assemblage
/// des mots est tenu par l'intégration continue à chaque commit, ce qu'une
/// vue iOS n'est pas. La seconde est qu'elle porte une **décision** — « ça
/// avance » contre « c'est figé » — et une décision n'appartient pas à une vue.
///
/// **D'où ça vient.** Une capture d'un noyau Arch sous wisq : quelques lignes,
/// puis plus rien pendant dix minutes. Rien à l'écran ne distinguait un invité
/// qui tourne en rond d'un invité mort, et ces deux-là ne se corrigent pas du
/// tout pareil. L'application avait le compteur ; elle ne le montrait nulle
/// part.
public enum GuestHeartbeat {
    /// Au bout de combien de temps sans une seule instruction on dit « figée ».
    ///
    /// **Deux secondes, pas zéro.** Un intervalle peut tomber entre deux
    /// publications sans que rien n'aille mal — le fil publie sur la cadence
    /// de vidage de la console, pas à la milliseconde. Crier au blocage sur un
    /// seul intervalle vide donnerait une alerte qui clignote, et une alerte
    /// qui clignote ne veut plus rien dire.
    public static let stallAfter: TimeInterval = 2

    /// Ce qu'il faut afficher, à partir de deux relevés.
    ///
    /// `since` est le relevé précédent et `seconds` le temps qui les sépare.
    /// Sans précédent — le premier tour — la vitesse est inconnue, et la
    /// phrase le dit en ne la donnant pas plutôt qu'en affichant zéro.
    public static func line(
        now: GuestProgress, since: GuestProgress?, seconds: TimeInterval
    ) -> String {
        let count = instructions(now.retired)
        guard let since, seconds > 0 else { return count }
        let ran = now.retired &- since.retired
        // **Le blocage se nomme, et il donne l'adresse.** Un compteur figé dit
        // *que* c'est bloqué ; l'adresse dit **où**, et c'est la moitié avec
        // laquelle on peut faire quelque chose — la retrouver dans le noyau
        // nomme la fonction qui tourne en rond.
        if ran == 0 && seconds >= stallAfter {
            return "\(count) — figée depuis \(Int(seconds)) s sur \(address(now.rip))"
        }
        let mips = Double(ran) / seconds / 1e6
        return "\(count) · \(speed(mips))"
    }

    /// Un nombre d'instructions, en français et sans faire lire douze chiffres.
    static func instructions(_ retired: UInt64) -> String {
        let value = Double(retired)
        switch retired {
        case 0: return "aucune instruction"
        case 1: return "1 instruction"
        case ..<1_000_000: return "\(retired) instructions"
        case ..<1_000_000_000:
            return "\(rounded(value / 1e6)) millions d'instructions"
        default:
            let billions = value / 1e9
            // « Un milliard » s'accorde, « milliards » aussi : à 1,0 le mot
            // reste au singulier, et l'écrire au pluriel se voit.
            return "\(rounded(billions)) milliard\(billions >= 2 ? "s" : "") d'instructions"
        }
    }

    static func speed(_ mips: Double) -> String {
        // Sous un million par seconde, « 0 MIPS » se lirait « à l'arrêt »
        // alors que ça tourne. Le nombre change d'unité plutôt que de mentir.
        if mips < 1 { return "\(Int((mips * 1000).rounded())) mille instructions par seconde" }
        return "\(rounded(mips)) MIPS"
    }

    /// Une adresse invitée, en hexadécimal, telle qu'un désassembleur la rend.
    static func address(_ rip: UInt64) -> String { "0x" + String(rip, radix: 16) }

    /// Une décimale, et la virgule française plutôt que le point.
    private static func rounded(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}
