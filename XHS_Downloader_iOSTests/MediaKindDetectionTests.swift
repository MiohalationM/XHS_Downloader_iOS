import Foundation
import Testing
@testable import XHS_Downloader_iOS

private final class MediaKindFixtureBundle: NSObject {}

/// Regression coverage for the review finding that a raw `ftyp` byte check
/// classified HEIC stills as video. The samples are the project's existing real
/// Live Photo fixtures, not synthetic bytes.
struct MediaKindDetectionTests {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle(for: MediaKindFixtureBundle.self).url(forResource: name, withExtension: ext))
    }

    /// A HEIC still is an ISO-BMFF container ("ftypheic"), so it must not be
    /// reported as a movie.
    @Test func heicStillIsNotVideo() async throws {
        let still = try fixture("livephoto-original", "heic")
        #expect(!MediaFileValidator.isVideoFile(still))
    }

    /// The paired motion component is a real movie and must be detected.
    @Test func pairedMotionIsVideo() async throws {
        let motion = try fixture("livephoto-motion", "mp4")
        #expect(MediaFileValidator.isVideoFile(motion))
    }

    @Test func missingFileIsNotVideo() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        #expect(!MediaFileValidator.isVideoFile(url))
    }
}
