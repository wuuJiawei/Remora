import Foundation

public enum TerminalColor: Equatable, Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case trueColor(UInt8, UInt8, UInt8)
}

public struct TerminalAttributes: Equatable, Hashable, Sendable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    public var inverse: Bool

    public init(
        foreground: TerminalColor = .default,
        background: TerminalColor = .default,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        inverse: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
    }

    public static let `default` = TerminalAttributes()
}
