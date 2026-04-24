import SwiftData
import Foundation

@Model final class Note {
    var title: String
    var body: String
    var createdAt: Date

    init(title: String, body: String) {
        self.title = title
        self.body = body
        self.createdAt = Date()
    }
}
