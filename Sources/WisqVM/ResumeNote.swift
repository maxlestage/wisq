import Foundation

/// **La phrase qui dit qu'une machine vient d'être reprise**, et d'où.
///
/// Une reprise après suspension garde la console : c'est le même écran, la
/// personne n'a rien vu partir. Mais depuis la sauvegarde continue
/// (`CheckpointedRun`), une machine peut aussi revenir après une application
/// **tuée** — et alors la console repart vide, sur un invité qui attend en
/// silence à son invite. Sans un mot, ça ressemble à une machine bloquée, ou
/// à rien du tout. Cette ligne dit ce qui s'est passé, quand, et quoi faire.
public enum ResumeNote {
    /// « Reprise de la sauvegarde automatique de 17 h 05 (il y a 12 min). »
    /// suivi de ce qu'il faut taper. `savedAt` est l'heure du fichier ; sans
    /// elle, la phrase se passe de l'heure plutôt que d'en inventer une.
    public static func text(savedAt: Date?, now: Date, timeZone: TimeZone = .current) -> String {
        var line = savedAt == nil ? "Reprise de la dernière sauvegarde automatique"
            : "Reprise de la sauvegarde automatique"
        if let savedAt {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.day, .month, .hour, .minute], from: savedAt)
            let clock = String(format: "%d h %02d", parts.hour ?? 0, parts.minute ?? 0)
            let sameDay = calendar.isDate(savedAt, inSameDayAs: now)
            line += sameDay ? " de \(clock)" : String(format: " du %02d/%02d à ", parts.day ?? 0, parts.month ?? 0) + clock
            line += " (\(age(from: savedAt, to: now)))"
        }
        return line + ". Appuyez sur Entrée pour retrouver l'invite."
    }

    /// L'âge en mots : à la minute près, puis à l'heure, puis au jour.
    static func age(from savedAt: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(savedAt))
        switch seconds {
        case ..<60: return "à l'instant"
        case ..<3600: return "il y a \(Int(seconds / 60)) min"
        case ..<86_400: return "il y a \(Int(seconds / 3600)) h"
        default:
            let days = Int(seconds / 86_400)
            return "il y a \(days) jour\(days > 1 ? "s" : "")"
        }
    }
}
