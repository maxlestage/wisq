import Foundation

/// **Le bureau de la machine locale** : un serveur VNC dans l'invité, joint
/// par le client VNC de wisq à travers un port relayé de l'hôte (voir
/// `HostStreams.forward` dans WisqVM).
///
/// La machine décrite ici n'entre jamais dans la bibliothèque : elle n'existe
/// que tant que la machine locale tourne, et son port change à chaque
/// démarrage.
public enum LocalDesktop {
    /// Le port du premier écran VNC, celui où `x11vnc` et `wayvnc` écoutent
    /// par défaut.
    public static let guestPort: UInt16 = 5900

    /// Ce qu'il faut lancer dans l'invité pour que le bureau réponde.
    public static let hint = """
        Dans l'invité, un serveur VNC sur le port 5900 : « x11vnc -forever \
        -nopw » sous X11, « wayvnc 0.0.0.0 » sous Wayland.
        """

    /// La connexion au bureau, par `127.0.0.1:port` — la boucle locale, où le
    /// port relayé écoute. Sans chiffrement ni mot de passe : rien ne quitte
    /// le téléphone.
    public static func machine(port: UInt16, name: String) -> Machine {
        Machine(name: name, host: "127.0.0.1", port: Int(port), proto: .vnc,
                security: .none, guestOS: .linux)
    }
}
