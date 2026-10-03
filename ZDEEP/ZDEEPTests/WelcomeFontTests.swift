import CoreText
import Testing
import UIKit

struct WelcomeFontTests {
    @Test
    func bundledInterFacesIncludeCyrillicGlyphs() {
        let faces = [
            "Inter-Regular",
            "Inter-Medium",
            "Inter-SemiBold",
            "Inter-Bold"
        ]

        for name in faces {
            guard let font = UIFont(name: name, size: 16) else {
                Issue.record("Missing bundled font face: \(name)")
                continue
            }

            let characterSet = CTFontCopyCharacterSet(font as CTFont)
            #expect(CFCharacterSetIsLongCharacterMember(characterSet, 0x0416)) // Ж
            #expect(CFCharacterSetIsLongCharacterMember(characterSet, 0x044F)) // я
        }
    }
}
