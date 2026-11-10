import Foundation

extension String {
    /// The lines of a text file, whichever line ending it has.
    ///
    /// `components(separatedBy: "\n")` splits a CRLF file on macOS, where it works on UTF-16 units, but not on Linux, where
    /// a CRLF is one `Character` that is not "\n" — and several of the corpus files are CRLF.
    var textLines: [String] {
        split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.map(String.init)
    }
}
