import AppKit
import SwiftUI

enum DeviceProduct: String, CaseIterable {
    case au05
    var title: String { "AU05" }
}

/// Coordinates projected from the same revision B scene as the complete 3D render.
enum AU05ArtworkLayout {
    struct Part {
        let center: CGPoint
        let size: CGSize
    }
    static let size = CGSize(width: 320, height: 1000)
    static let knob = Part(center: CGPoint(x: 143.305, y: 343.541), size: CGSize(width: 205.005, height: 215.187))
    static let keys = [539.694, 681.475, 823.256].map {
        Part(center: CGPoint(x: 146.341, y: $0), size: CGSize(width: 144.898, height: 142.902))
    }
}

/// Complete project-authored 3D artwork; never substitute a simplified device.
struct DeviceProductArtwork: View {
    let product: DeviceProduct
    var compact = false
    static let au05Image = Bundle.main.url(forResource: "au05-3d", withExtension: "png", subdirectory: "Devices")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        Group {
            if let image = Self.au05Image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Text("AU05 设备图未载入").font(VIFLOWTheme.caption)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
