import Testing
@testable import RemoraApp

struct AppAppearanceModeTests {
    @Test
    func resolvedFallsBackToSystemForUnknownValue() {
        #expect(AppAppearanceMode.resolved(from: "unknown") == .system)
    }

    @Test
    func resolvedParsesKnownValues() {
        #expect(AppAppearanceMode.resolved(from: "system") == .system)
        #expect(AppAppearanceMode.resolved(from: "light") == .light)
        #expect(AppAppearanceMode.resolved(from: "dark") == .dark)
    }
}
