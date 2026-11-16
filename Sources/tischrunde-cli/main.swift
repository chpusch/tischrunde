import Foundation
import TischrundeCore
import TischrundeIO

// Minimal command line front end. Real commands follow in milestone 3.
let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--version") {
    print("tischrunde \(TischrundeVersion.string)")
} else {
    print("""
    tischrunde \(TischrundeVersion.string)
    Verwendung: tischrunde-cli --version
    (Weitere Befehle folgen.)
    """)
}
