import Foundation

enum EditorLanguage: String, Codable, CaseIterable, Identifiable {
    case plain
    case javascript
    case typescript
    case python
    case json
    case yaml
    case markdown
    case html
    case css
    case sql
    case rust
    case go
    case cpp
    case c
    case java
    case xml
    case shell
    case dockerfile
    case toml

    var id: String { rawValue }

    static func infer(from path: String?) -> EditorLanguage {
        guard let path else { return .plain }
        let lower = path.lowercased()

        if lower.hasSuffix(".js") || lower.hasSuffix(".jsx") || lower.hasSuffix(".mjs") { return .javascript }
        if lower.hasSuffix(".ts") || lower.hasSuffix(".tsx") { return .typescript }
        if lower.hasSuffix(".py") { return .python }
        if lower.hasSuffix(".json") || lower.hasSuffix(".jsonc") { return .json }
        if lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") { return .yaml }
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { return .markdown }
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") { return .html }
        if lower.hasSuffix(".css") || lower.hasSuffix(".scss") || lower.hasSuffix(".sass") { return .css }
        if lower.hasSuffix(".sql") { return .sql }
        if lower.hasSuffix(".rs") { return .rust }
        if lower.hasSuffix(".go") { return .go }
        if lower.hasSuffix(".cpp") || lower.hasSuffix(".cc") || lower.hasSuffix(".cxx") || lower.hasSuffix(".hpp") { return .cpp }
        if lower.hasSuffix(".c") || lower.hasSuffix(".h") { return .c }
        if lower.hasSuffix(".java") { return .java }
        if lower.hasSuffix(".xml") || lower.hasSuffix(".plist") { return .xml }
        if lower.hasSuffix(".sh") || lower.hasSuffix(".bash") || lower.hasSuffix(".zsh") { return .shell }
        if lower.hasSuffix("dockerfile") || lower.hasSuffix(".dockerfile") { return .dockerfile }
        if lower.hasSuffix(".toml") { return .toml }

        return .plain
    }
}
