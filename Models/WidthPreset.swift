import Foundation

struct WidthPreset: Codable, Identifiable, Hashable {
    let id: UUID
    var width: Int
    var label: String
    var isBuiltIn: Bool
    var isEnabled: Bool

    init(width: Int, label: String? = nil, isBuiltIn: Bool = false, isEnabled: Bool = true) {
        self.id = UUID()
        self.width = width
        self.label = label ?? "\(width)px"
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        width = try container.decode(Int.self, forKey: .width)
        label = try container.decode(String.self, forKey: .label)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
