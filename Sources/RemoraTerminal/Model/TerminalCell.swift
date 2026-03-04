import Foundation

public struct TerminalCell: Equatable, Hashable, Sendable {
    public var character: Character
    public var attributes: TerminalAttributes
    public var displayWidth: UInt8
    public var hyperlink: String?

    public init(
        character: Character = " ",
        attributes: TerminalAttributes = .default,
        displayWidth: UInt8 = 1,
        hyperlink: String? = nil
    ) {
        self.character = character
        self.attributes = attributes
        self.displayWidth = displayWidth
        self.hyperlink = hyperlink
    }
}
