import Foundation
import Testing
@testable import ZDEEP

struct DiagnosticMailboxLaunchTests {
    @Test func diagnosticWebViewAutoOpenRequiresTheDedicatedExplicitFlag() {
        let optedIn = LaunchConfiguration(
            arguments: ["--environment", "local", "--usb-diagnostics"],
            variables: [:]
        )
        let explicitOpen = LaunchConfiguration(
            arguments: ["--environment", "local", "--usb-diagnostics", "--usb-diagnostics-open-webview"],
            variables: [:]
        )
        let withoutDiagnostics = LaunchConfiguration(arguments: ["--environment", "local"], variables: [:])

        #expect(optedIn.usbDiagnosticsEnabled)
        #expect(!optedIn.usbDiagnosticsOpenWebViewEnabled)
        #expect(explicitOpen.usbDiagnosticsOpenWebViewEnabled)
        #expect(!withoutDiagnostics.usbDiagnosticsOpenWebViewEnabled)
    }
}
