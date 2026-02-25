import Foundation

struct AspectRatio: Codable, Identifiable, Hashable {
    let id: UUID
    var widthComponent: Int
    var heightComponent: Int
    var isBuiltIn: Bool
    var isEnabled: Bool

    var label: String { "\(widthComponent):\(heightComponent)" }
    var ratio: Double { Double(widthComponent) / Double(heightComponent) }

    func height(forWidth width: Int) -> Int {
        Int(round(Double(width) / ratio))
    }

    init(widthComponent: Int, heightComponent: Int, isBuiltIn: Bool = false, isEnabled: Bool = true) {
        self.id = UUID()
        self.widthComponent = widthComponent
        self.heightComponent = heightComponent
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        widthComponent = try container.decode(Int.self, forKey: .widthComponent)
        heightComponent = try container.decode(Int.self, forKey: .heightComponent)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
