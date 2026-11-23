import Foundation
import Testing
@testable import XHS_Downloader_iOS

struct ResolvedNotePolicyTests {
    private let noteURL = URL(string: "https://www.xiaohongshu.com/explore/target")!

    @Test(arguments: ["imageList", "images"])
    func videoImageListCoverHonorsTheCoverSwitch(imageField: String) throws {
        let note = try XHSDownloader().resolveNote(data: [
            "noteId": "target", "type": "video",
            "video": ["consumer": ["originVideoKey": "video-key"]],
            imageField: [["fileId": "cover-key", "urlDefault": "https://media.example/cover.jpg"]]
        ], noteID: "target", canonicalURL: noteURL)

        var policy = DownloadPolicy()
        #expect(note.media.filter(policy.includes).map(\.type) == [.video])

        policy.covers = true
        #expect(note.media.filter(policy.includes).map(\.type) == [.video, .image])
        policy.images = false
        policy.videos = false
        let covers = note.media.filter(policy.includes)
        #expect(covers.count == 1)
        #expect(covers.first?.fileKey == "cover-key")

        policy.covers = false
        #expect(note.media.filter(policy.includes).isEmpty)
    }

    @Test(arguments: ["normal", "video"])
    func coverClassificationPreservesBodyImagesAndLivePhotoPairs(noteType: String) throws {
        let motion = "https://media.example/motion.mp4"
        let note = try XHSDownloader().resolveNote(data: [
            "noteId": "target", "type": noteType,
            "video": ["consumer": ["originVideoKey": "video-key"]],
            "imageList": [
                ["urlDefault": "https://media.example/still.jpg"],
                ["urlDefault": "https://media.example/live.jpg",
                 "stream": ["h264": [["masterUrl": motion]]]]
            ]
        ], noteID: "target", canonicalURL: noteURL)

        let selected = note.media.filter(DownloadPolicy().includes)
        let expected: [RemoteMedia.MediaType] = noteType == "video"
            ? [.video, .livePhoto] : [.video, .image, .livePhoto]
        #expect(selected.map(\.type) == expected)
        #expect(selected.last?.pairedVideoURLs.map(\.absoluteString) == [motion])
    }

    @Test(arguments: ["target", "alias"])
    func htmlSiblingCommentsStayWithTheirTargetNote(mapKey: String) throws {
        let comments: [String: Any] = ["list": [[
            "id": "comment-1", "pictures": [["urlDefault": "https://media.example/comment.jpg"]]
        ]]]
        let unrelated: [String: Any] = ["list": [[
            "id": "other-comment", "pictures": [["urlDefault": "https://media.example/unrelated.jpg"]]
        ]]]
        let root: [String: Any] = ["note": [
            "noteDetailMap": [
                mapKey: [
                    "note": ["noteId": "target", "title": "Text note", "desc": "Body"],
                    "comments": comments
                ],
                "recommended": ["note": ["noteId": "other"], "comments": unrelated]
            ],
            "comments": unrelated
        ]]
        let note = try resolveHTML(root)

        var policy = DownloadPolicy()
        #expect(note.media.filter(policy.includes).isEmpty)
        policy.comments = true
        policy.images = false
        let images = note.media.filter(policy.includes)
        #expect(images.map(\.url.absoluteString) == ["https://media.example/comment.jpg"])
        #expect(images.allSatisfy { $0.role == .comment })
        #expect(note.body == "Body")
    }

    @Test(arguments: ["comments", "commentData"])
    func embeddedCommentsRemainAvailableWithoutSiblingComments(commentField: String) throws {
        let note: [String: Any] = [
            "noteId": "target",
            commentField: ["list": [[
                "id": "comment-1", "pictures": [["urlDefault": "https://media.example/comment.jpg"]]
            ]]]
        ]
        let root: [String: Any] = ["note": ["noteDetailMap": ["target": ["note": note]]]]
        let resolved = try resolveHTML(root)

        var policy = DownloadPolicy()
        policy.comments = true
        #expect(resolved.media.filter(policy.includes).map(\.url.absoluteString) == [
            "https://media.example/comment.jpg"
        ])
    }

    private func resolveHTML(_ root: [String: Any]) throws -> ResolvedNote {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        let html = "<script>window.__INITIAL_STATE__ = \(json);</script>"
        return try XHSDownloader().resolveNote(html: html, noteID: "target", canonicalURL: noteURL)
    }
}
