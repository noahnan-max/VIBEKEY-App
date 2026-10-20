import SwiftUI

enum DeviceProduct: String, CaseIterable {
    case au05
    var title: String { "AU05" }
}

/// Original schematic aligned with the editor's 188 × 692 hit map.
/// No manufacturer's application resource or product photograph is redistributed.
struct DeviceProductArtwork: View {
    let product: DeviceProduct
    var compact = false
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 188, geometry.size.height / 692)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 34).fill(Color(white: 0.22))
                    .overlay(RoundedRectangle(cornerRadius: 34).stroke(Color(white: 0.44), lineWidth: 3))
                    .frame(width: 180, height: 676).position(x: 94, y: 346)
                Capsule().fill(Color(white: 0.12)).frame(width: 34, height: 6).position(x: 94, y: 67)
                Circle().fill(Color(white: 0.12))
                    .overlay(Circle().stroke(Color(white: 0.54), lineWidth: 6))
                    .overlay(Circle().stroke(Color(white: 0.30), lineWidth: 1).padding(12))
                    .frame(width: 164, height: 164).position(x: 94, y: 210)
                ForEach([370.0, 484.0, 598.0], id: \.self) { center in
                    RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.82))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.95), lineWidth: 2))
                        .frame(width: 118, height: 84).position(x: 94, y: center)
                }
            }.frame(width: 188, height: 692).scaleEffect(scale)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.aspectRatio(188.0 / 692.0, contentMode: .fit)
            .accessibilityHidden(true).allowsHitTesting(false)
    }
}
