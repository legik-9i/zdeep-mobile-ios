import CryptoKit
import Testing
import UIKit
import WebKit
@testable import ZDEEP

struct WelcomeResourceTests {
    @Test @MainActor
    func nativeBackgroundUsesExactSrgbColor() throws {
        let color = try #require(UIColor(named: "NativeBackground"))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(abs(red - 245.0 / 255) < 0.00001)
        #expect(abs(green - 245.0 / 255) < 0.00001)
        #expect(abs(blue - 247.0 / 255) < 0.00001)
        #expect(abs(alpha - 1) < 0.00001)
    }

    @Test @MainActor
    func webViewHostAppliesNativeBackgroundToWebAndScrollViews() throws {
        let session = WebSession()
        defer { session.close() }
        let webView = session.webView
        WebViewHost.configureBackground(for: webView)
        let expected = try #require(UIColor(named: "NativeBackground"))

        #expect(webView.backgroundColor?.isEqual(expected) == true)
        #expect(webView.scrollView.backgroundColor?.isEqual(expected) == true)
        #expect(webView.underPageBackgroundColor?.isEqual(expected) == true)
    }

    @Test @MainActor
    func welcomeArtworkAndInterLicenseArePackaged() throws {
        for asset in ["WelcomeHero", "WelcomeBolt", "WelcomeScan", "WelcomeHelp"] {
            #expect(UIImage(named: asset) != nil)
        }

        let licenseURL = try #require(Bundle.main.url(forResource: "Inter-OFL", withExtension: "txt"))
        let licenseData = try Data(contentsOf: licenseURL)
        let license = try #require(String(data: licenseData, encoding: .utf8))

        #expect(license.contains("SIL OPEN FONT LICENSE Version 1.1"))
        #expect(license.contains("PREAMBLE"))
        #expect(license.contains("TERMINATION"))
        #expect(license.contains("DISCLAIMER"))
        let licenseDigest = SHA256.hash(data: licenseData).map { String(format: "%02x", $0) }.joined()
        #expect(licenseDigest == "3b0a5fca3d17942cde889069889dedbbbd075e9b599968c82a95f4d944e9b345")

        let symbolLicenseURL = try #require(Bundle.main.url(forResource: "Material-Symbols-LICENSE", withExtension: "txt"))
        let symbolLicense = try String(contentsOf: symbolLicenseURL, encoding: .utf8)
        #expect(symbolLicense.contains("Apache License"))
        #expect(symbolLicense.contains("Version 2.0, January 2004"))

        let sourceURL = try #require(Bundle.main.url(forResource: "WelcomeHelpSource", withExtension: "json"))
        let sourceData = try Data(contentsOf: sourceURL)
        let source = try JSONDecoder().decode(HelpSymbolSource.self, from: sourceData)

        #expect(source.family == "Material Symbols Outlined")
        #expect(source.glyph == "help_outline")
        #expect(source.resolvedGlyph == "help")
        #expect(source.axes == ["opsz": 24, "wght": 400, "FILL": 0, "GRAD": 0])
    }
}

private struct HelpSymbolSource: Decodable {
    let family: String
    let glyph: String
    let resolvedGlyph: String
    let axes: [String: Int]
}
