import Foundation

struct WidthPreset: Codable, Identifiable, Hashable {
    let id: UUID
    var width: Int
    var label: String
    var isBuiltIn: Bool

    init(width: Int, label: String? = nil, isBuiltIn: Bool = false) {
        self.id = UUID()
        self.width = width
        self.label = label ?? "\(width)px"
        self.isBuiltIn = isBuiltIn
    }
}
