import Testing
@testable import FoscoCore

@Suite struct InstallLocation {
    @Test(arguments: ["/Applications/Fosco.app", "/Users/someone/Applications/Fosco.app", "/Users/someone/Downloads/Fosco.app"])
    func acceptsFoldersTheAppCanStayIn(path: String) {
        #expect(!isTemporaryLocation(path: path, volumeIsReadOnly: false))
    }

    @Test func rejectsTheCopyMacOSMakesOfADownloadedApp() {
        let path = "/private/var/folders/6n/abc/T/AppTranslocation/0C1D2E3F-1111-2222-3333-444455556666/d/Fosco.app"
        #expect(isTemporaryLocation(path: path, volumeIsReadOnly: false))
    }

    @Test func rejectsADiskImage() {
        #expect(isTemporaryLocation(path: "/Volumes/Fosco/Fosco.app", volumeIsReadOnly: true))
    }
}
