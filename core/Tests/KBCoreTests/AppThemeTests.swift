import Testing
@testable import KBCore

@Suite struct AppThemeTests {
    @Test func hexRoundTripsAndJudgesDarkness() {
        let c = AppTheme.rgb("#0A84FF")!
        #expect(AppTheme.hex(r: c.r, g: c.g, b: c.b) == "#0A84FF")
        #expect(AppTheme.rgb("nope") == nil)
        #expect(AppTheme.isDark("#000000") == true)
        #expect(AppTheme.isDark("#FBF8F2") == false)
        #expect(AppTheme.isDark("") == nil)
    }

    @Test func themesSaveAndTokensEdit() {
        var t = AppTheme.presets.first { $0.name == "Ocean" }!
        t[.selection] = "#112233"
        #expect(t.selection == "#112233")
        #expect(AppTheme.decode(t.encoded()) == t)
        #expect(t.hasBackgrounds)
        #expect(!AppTheme.standard.hasBackgrounds)
        #expect(Set(AppTheme.presets.map(\.name)).count == AppTheme.presets.count)
    }

    @Test func themeSavedUnderTheOldAppNameIsTheDefault() {
        var old = AppTheme.standard
        old.name = "KB"
        #expect(AppTheme.decode(old.encoded()) == AppTheme.standard)
    }

    @Test func pairsHoldALightAndADarkColour() {
        #expect(AppTheme.variants(AppTheme.brand) == ("#1F3A6E", "#B0C6FF"))
        #expect(AppTheme.variants("#112233") == ("#112233", "#112233"))
        #expect(AppTheme.rgb(AppTheme.brand) != nil)
    }

    @Test func theOldStandardThemeTakesTheLogoColour() {
        #expect(AppTheme.decode(AppTheme.previousStandard.encoded()) == AppTheme.standard)
        var mine = AppTheme.previousStandard
        mine.accent = "#FF0000"
        #expect(AppTheme.decode(mine.encoded()) == mine)
    }
}
