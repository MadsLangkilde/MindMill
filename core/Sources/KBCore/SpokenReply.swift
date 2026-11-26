import Foundation

/// A message the user said out loud on a phone, whose reply the phone reads aloud: Claude is asked to answer the way
/// one talks. The note goes to Claude only; the transcript shows what the user said.
public enum SpokenReply {
    public static let note = "(Said out loud on the phone, and everything you write is read aloud. Answer in two or three short spoken sentences: no headings, tables, code or links. When the work takes more than a few steps, write a one-sentence update when you find or decide something I'd want to know, in plain words; keep commands, file names and tool talk out of these, and write nothing else between steps. When you need me to choose, still end with a choices block of short options.)"

    public static func message(_ said: String) -> String {
        "\(said.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(note)"
    }
}
