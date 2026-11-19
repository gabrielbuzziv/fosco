import Foundation
import FoscoCore

/// Where screenshots get saved on this Mac.
///
/// Screenshot apps keep their own setting for this in their sandbox, out of reach, so the folders
/// that hold nothing but captures are the conventional ~/Pictures/Screenshots plus any path listed
/// in the `screenshotFolders` preference:
/// `defaults write com.gabrielbuzzi.fosco screenshotFolders -array-add "/some/folder"`
func screenshotFolders(defaults: UserDefaults = .standard) -> [FolderGuard.Folder] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    func url(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }
    var isDirectory: ObjCBool = false
    let dedicated = ([home.appending(path: "Pictures/Screenshots")] + (defaults.stringArray(forKey: "screenshotFolders") ?? []).map(url))
        .filter { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue }
    // macOS saves to the Desktop unless told otherwise, and tags every capture it writes.
    let systemSetting = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
    let systemFolder = systemSetting.flatMap { $0.isEmpty ? nil : url($0) } ?? home.appending(path: "Desktop")

    var folders: [FolderGuard.Folder] = []
    for folder in dedicated.map({ FolderGuard.Folder(url: $0, scope: .everyImage) }) + [FolderGuard.Folder(url: systemFolder, scope: .flaggedScreenshots)]
    where !folders.contains(where: { $0.url == folder.url }) {
        folders.append(folder)
    }
    return folders
}
