import Foundation

struct VideoFileItem: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}
