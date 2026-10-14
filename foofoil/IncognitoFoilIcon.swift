import AppKit

/// 同一模板图像用于菜单、空箔和总览；斜线两侧留出透明间隙，保持小尺寸下的可辨识度。
enum IncognitoFoilIcon {
    static let image: NSImage = {
        let size = NSSize(width: 32, height: 32)
        let symbol = NSImage(systemSymbolName: "shoeprints.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.black]))
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let symbol, let context = NSGraphicsContext.current?.cgContext else { return false }
            let available = bounds.insetBy(dx: 3, dy: 3)
            let scale = min(available.width / symbol.size.width, available.height / symbol.size.height)
            let symbolSize = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: NSRect(x: bounds.midX - symbolSize.width / 2,
                                   y: bounds.midY - symbolSize.height / 2,
                                   width: symbolSize.width, height: symbolSize.height))
            context.saveGState()
            context.setLineCap(.round)
            for (blend, width) in [(CGBlendMode.destinationOut, CGFloat(5.5)), (.normal, CGFloat(2.5))] {
                context.setBlendMode(blend)
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(width)
                context.move(to: CGPoint(x: 4, y: 28))
                context.addLine(to: CGPoint(x: 28, y: 4))
                context.strokePath()
            }
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = NSLocalizedString("Incognito Foil", comment: "")
        return image
    }()

    static var menuImage: NSImage {
        let image = image.copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
