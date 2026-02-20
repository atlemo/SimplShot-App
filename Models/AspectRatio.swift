import Foundation

struct AspectRatio: Codable, Identifiable, Hashable {
    let id: UUID
    var widthComponent: Int
    var heightComponent: Int
    var isBuiltIn: Bool

    var label: String { "\(widthComponent):\(heightComponent)" }
    var ratio: Double { Double(widthComponent) / Double(heightComponent) }

    func height(forWidth width: Int) -> Int {
        Int(round(Double(width) / ratio))
    }

    init(widthComponent: Int, heightComponent: Int, isBuiltIn: Bool = false) {
        self.id = UUID()
        self.widthComponent = widthComponent
        self.heightComponent = heightComponent
        self.isBuiltIn = isBuiltIn
    }
}
