import Foundation

public struct TerminalCell: Equatable, Hashable, Sendable {
    public var character: Character
    public var attributes: TerminalAttributes
    public var displayWidth: UInt8

    public init(
        character: Character = " ",
        attributes: TerminalAttributes = .default,
        displayWidth: UInt8 = 1
    ) {
        self.character = character
        self.attributes = attributes
        self.displayWidth = displayWidth
    }
}
