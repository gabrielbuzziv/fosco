import CoreGraphics
import Foundation
import Testing
@testable import FoscoCore

@Suite struct ShottrHandoff {
    private let copiedAt = Date(timeIntervalSinceReferenceDate: 1000)
    private let editor = ShottrWindow(number: 7, layer: 0, size: CGSize(width: 1520, height: 812))
    private let thumbnail = ShottrWindow(number: 9, layer: 1000, size: CGSize(width: 206, height: 175))

    private func view(
        of windows: [ShottrWindow], before: Set<Int> = [], isFrontmost: Bool = false, leftTheFrontAfter seconds: TimeInterval? = nil
    ) -> ShottrView? {
        shottrView(
            of: windows, onScreenBefore: before, isFrontmost: isFrontmost,
            lastDeactivated: seconds.map(copiedAt.addingTimeInterval), copiedAt: copiedAt
        )
    }

    @Test func findsTheCaptureInTheEditorInFront() {
        #expect(view(of: [editor], before: [7], isFrontmost: true) == .editor)
    }

    @Test func stillDoesWhenTheUserClickedAwayWhileTheCaptureWasRead() {
        #expect(view(of: [editor], before: [7], leftTheFrontAfter: 0.8) == .editor)
    }

    @Test func leavesAnEditorLeftOpenBehindAnotherAppAlone() {
        #expect(view(of: [editor], before: [7], leftTheFrontAfter: -30) == nil)
        #expect(view(of: [editor], before: [7]) == nil)
    }

    @Test func findsTheCaptureInAThumbnailThatCameUpAlthoughShottrNeverCameToTheFront() {
        #expect(view(of: [thumbnail], leftTheFrontAfter: -216) == .thumbnail)
    }

    @Test func prefersTheEditorOnceTheThumbnailWasOpenedInIt() {
        #expect(view(of: [thumbnail, editor], isFrontmost: true) == .editor)
    }

    @Test func leavesTheThumbnailOfAnEarlierCaptureAlone() {
        #expect(view(of: [thumbnail], before: [9]) == nil)
    }

    @Test func doesNotTakeShottrsOtherFloatingWindowsForAThumbnail() {
        let confirmation = ShottrWindow(number: 11, layer: 101, size: CGSize(width: 422, height: 169))
        let areaSelection = ShottrWindow(number: 12, layer: 1000, size: CGSize(width: 2560, height: 1440))
        #expect(view(of: [confirmation, areaSelection]) == nil)
    }

    @Test func findsNothingWhenShottrShowsNothing() {
        #expect(view(of: [], isFrontmost: true) == nil)
    }
}
