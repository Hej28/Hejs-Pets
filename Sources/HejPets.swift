import AppKit
import Vision
import CoreImage
import UniformTypeIdentifiers

// MARK: - Small helpers

extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let number = Int(value, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#8AA6A3" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    func mixed(with other: NSColor, amount: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        let t = min(1, max(0, amount))
        return NSColor(
            srgbRed: a.redComponent * (1-t) + b.redComponent * t,
            green: a.greenComponent * (1-t) + b.greenComponent * t,
            blue: a.blueComponent * (1-t) + b.blueComponent * t,
            alpha: a.alphaComponent * (1-t) + b.alphaComponent * t
        )
    }
}

extension NSImage {
    var cgImageValue: CGImage? {
        var proposed = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }
}

func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
    min(high, max(low, value))
}

// MARK: - Persistence and lightweight local photo analysis

struct FaceFeatureRecord: Codable, Equatable {
    var leftEye: CGPoint
    var rightEye: CGPoint
    var mouth: CGPoint
}

struct PaintStroke: Codable, Equatable {
    var points: [CGPoint]       // Normalized, top-left origin.
    var radius: CGFloat         // Normalized against the image's short side.
    var erasing: Bool
    var fillsInterior: Bool?    // Closed outline filled by outside flood-fill.
}

struct PetRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var imageFilename: String
    var headFilename: String?
    var headVersion: Int?
    var faceX: Double
    var faceY: Double
    var faceW: Double
    var faceH: Double
    var clothingX: Double?
    var clothingY: Double?
    var clothingW: Double?
    var clothingH: Double?
    var clothingTextureFilename: String?
    var faceFeatures: FaceFeatureRecord?
    var headMaskStrokes: [PaintStroke]?
    var clothingMaskStrokes: [PaintStroke]?
    var shirtHex: String
    var pantsHex: String
    var isVisible: Bool
}

final class PetStore {
    private(set) var pets: [PetRecord] = []
    let rootURL: URL
    private let imagesURL: URL
    private let jsonURL: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["HEJPETS_DATA_DIR"], !override.isEmpty {
            rootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            rootURL = base.appendingPathComponent("HejPets", isDirectory: true)
        }
        imagesURL = rootURL.appendingPathComponent("Images", isDirectory: true)
        jsonURL = rootURL.appendingPathComponent("pets.json")
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        load()
    }

    func imageURL(for pet: PetRecord) -> URL {
        imagesURL.appendingPathComponent(pet.imageFilename)
    }

    func headURL(for pet: PetRecord) -> URL? {
        guard let filename = pet.headFilename else { return nil }
        let url = imagesURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func clothingTextureURL(for pet: PetRecord) -> URL? {
        guard let filename = pet.clothingTextureFilename else { return nil }
        let url = imagesURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode([PetRecord].self, from: data) else { return }
        pets = decoded.filter { FileManager.default.fileExists(atPath: imageURL(for: $0).path) }
        var migrated = pets.count != decoded.count
        for index in pets.indices where headURL(for: pets[index]) == nil || (pets[index].headVersion ?? 0) < 2 {
            guard let source = NSImage(contentsOf: imageURL(for: pets[index]))?.cgImageValue else { continue }
            let face = CGRect(x: pets[index].faceX, y: pets[index].faceY, width: pets[index].faceW, height: pets[index].faceH)
            let filename = "\(pets[index].id.uuidString)-head.png"
            let destination = imagesURL.appendingPathComponent(filename)
            if let cutout = makeHeadCutout(from: source, face: face), writePNG(cutout, to: destination) {
                pets[index].headFilename = filename
                pets[index].headVersion = 2
                migrated = true
            }
        }
        // Version 4 used a top-origin paint bounding box as a bottom-origin crop.
        // Its brush strokes were not persisted, so rebuild only those known-bad
        // heads from the untouched source photo. The fixed brush editor writes v5.
        for index in pets.indices where pets[index].headVersion == 4 && pets[index].headMaskStrokes == nil {
            guard let source = NSImage(contentsOf: imageURL(for: pets[index]))?.cgImageValue else { continue }
            let face = CGRect(x: pets[index].faceX, y: pets[index].faceY, width: pets[index].faceW, height: pets[index].faceH)
            let filename = pets[index].headFilename ?? "\(pets[index].id.uuidString)-head.png"
            let destination = imagesURL.appendingPathComponent(filename)
            if let cutout = makeHeadCutout(from: source, face: face), writePNG(cutout, to: destination) {
                pets[index].headFilename = filename
                pets[index].headVersion = 6
                pets[index].faceFeatures = detectFacialFeatures(in: cutout)
                migrated = true
            }
        }
        // Early v5 stored large paint dabs instead of a filled outline. Repair
        // those results once from the untouched source and let the user choose
        // automatic, rectangular or filled freehand selection going forward.
        for index in pets.indices where pets[index].headVersion == 5 && (pets[index].headMaskStrokes?.contains { $0.fillsInterior == nil } ?? false) {
            guard let source = NSImage(contentsOf: imageURL(for: pets[index]))?.cgImageValue else { continue }
            let face = CGRect(x: pets[index].faceX, y: pets[index].faceY, width: pets[index].faceW, height: pets[index].faceH)
            let filename = pets[index].headFilename ?? "\(pets[index].id.uuidString)-head.png"
            if let cutout = makeHeadCutout(from: source, face: face), writePNG(cutout, to: imagesURL.appendingPathComponent(filename)) {
                pets[index].headFilename = filename
                pets[index].headVersion = 6
                pets[index].headMaskStrokes = nil
                pets[index].faceFeatures = detectFacialFeatures(in: cutout)
                migrated = true
            }
        }
        for index in pets.indices where pets[index].faceFeatures == nil {
            guard let url = headURL(for: pets[index]),
                  let head = NSImage(contentsOf: url)?.cgImageValue,
                  let features = detectFacialFeatures(in: head) else { continue }
            pets[index].faceFeatures = features
            migrated = true
        }
        if migrated { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pets) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }

    func addPhoto(at source: URL) throws -> PetRecord {
        guard let image = NSImage(contentsOf: source), let cgImage = image.cgImageValue else {
            throw NSError(domain: "HejPets", code: 1, userInfo: [NSLocalizedDescriptionKey: "这张图片无法读取，请换一张 JPG、PNG 或 HEIC。"])
        }

        let id = UUID()
        var ext = source.pathExtension.lowercased()
        if ext.isEmpty { ext = "jpg" }
        let filename = "\(id.uuidString).\(ext)"
        let destination = imagesURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)

        let face = detectFace(in: cgImage) ?? CGRect(x: 0.20, y: 0.43, width: 0.60, height: 0.52)
        let headFilename = "\(id.uuidString)-head.png"
        let headDestination = imagesURL.appendingPathComponent(headFilename)
        let headCutout = makeHeadCutout(from: cgImage, face: face)
        let didCreateHead = headCutout.map { writePNG($0, to: headDestination) } ?? false
        let features = headCutout.flatMap { detectFacialFeatures(in: $0) }
        let shirt = sampledColor(in: cgImage, yStart: 0.48, yEnd: 0.72, fallback: NSColor(hex: "#78A79F")!)
        let pants = sampledColor(in: cgImage, yStart: 0.72, yEnd: 0.92, fallback: shirt.mixed(with: .black, amount: 0.38))
        let number = pets.count + 1
        let record = PetRecord(
            id: id,
            name: "小宠物 \(number)",
            imageFilename: filename,
            headFilename: didCreateHead ? headFilename : nil,
            headVersion: didCreateHead ? 2 : nil,
            faceX: face.origin.x,
            faceY: face.origin.y,
            faceW: face.size.width,
            faceH: face.size.height,
            clothingX: nil,
            clothingY: nil,
            clothingW: nil,
            clothingH: nil,
            clothingTextureFilename: nil,
            faceFeatures: features,
            headMaskStrokes: nil,
            clothingMaskStrokes: nil,
            shirtHex: shirt.hexString,
            pantsHex: pants.hexString,
            isVisible: true
        )
        pets.append(record)
        save()
        return record
    }

    func remove(id: UUID) {
        guard let index = pets.firstIndex(where: { $0.id == id }) else { return }
        let record = pets.remove(at: index)
        try? FileManager.default.removeItem(at: imageURL(for: record))
        if let headURL = headURL(for: record) { try? FileManager.default.removeItem(at: headURL) }
        if let textureURL = clothingTextureURL(for: record) { try? FileManager.default.removeItem(at: textureURL) }
        save()
    }

    func setVisible(id: UUID, visible: Bool) {
        guard let index = pets.firstIndex(where: { $0.id == id }) else { return }
        pets[index].isVisible = visible
        save()
    }

    func clothingRect(for record: PetRecord) -> CGRect {
        if let x = record.clothingX, let y = record.clothingY,
           let width = record.clothingW, let height = record.clothingH,
           width > 0.03, height > 0.03 {
            return CGRect(x: x, y: y, width: width, height: height)
        }
        let face = CGRect(x: record.faceX, y: record.faceY, width: record.faceW, height: record.faceH)
        let width = min(0.62, max(0.16, face.width * 1.22))
        let height = min(0.32, max(0.10, face.height * 0.62))
        let x = clamp(face.midX - width / 2, 0, 1 - width)
        let top = clamp(face.minY + face.height * 0.04, height, 1)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    @discardableResult
    func updateClothingCrop(id: UUID, rect: CGRect?) -> PetRecord? {
        guard let index = pets.firstIndex(where: { $0.id == id }),
              let source = NSImage(contentsOf: imageURL(for: pets[index]))?.cgImageValue else { return nil }
        if let rect {
            let safe = CGRect(
                x: clamp(rect.minX, 0, 0.98), y: clamp(rect.minY, 0, 0.98),
                width: clamp(rect.width, 0.04, 1 - clamp(rect.minX, 0, 0.98)),
                height: clamp(rect.height, 0.04, 1 - clamp(rect.minY, 0, 0.98))
            )
            pets[index].clothingX = safe.minX
            pets[index].clothingY = safe.minY
            pets[index].clothingW = safe.width
            pets[index].clothingH = safe.height
        } else {
            if let url = clothingTextureURL(for: pets[index]) { try? FileManager.default.removeItem(at: url) }
            pets[index].clothingX = nil
            pets[index].clothingY = nil
            pets[index].clothingW = nil
            pets[index].clothingH = nil
            pets[index].clothingTextureFilename = nil
            pets[index].clothingMaskStrokes = nil
        }
        let region = clothingRect(for: pets[index])
        if let sample = cropNormalized(source, region: region) {
            pets[index].shirtHex = sampledColor(in: sample, yStart: 0, yEnd: 1, fallback: NSColor(hex: pets[index].shirtHex) ?? NSColor(hex: "#78A79F")!).hexString
        }
        save()
        return pets[index]
    }

    @discardableResult
    func updatePaintedClothing(id: UUID, strokes: [PaintStroke]) -> PetRecord? {
        guard let index = pets.firstIndex(where: { $0.id == id }),
              let source = NSImage(contentsOf: imageURL(for: pets[index]))?.cgImageValue,
              let (_, box) = makePaintMask(for: source, strokes: strokes),
              box.width > 0.015, box.height > 0.015,
              let texture = cropNormalized(source, region: box) else { return nil }
        let filename = "\(id.uuidString)-clothing.png"
        let destination = imagesURL.appendingPathComponent(filename)
        guard writePNG(texture, to: destination) else { return nil }
        if let old = clothingTextureURL(for: pets[index]), old.lastPathComponent != filename {
            try? FileManager.default.removeItem(at: old)
        }
        pets[index].clothingTextureFilename = filename
        pets[index].clothingMaskStrokes = strokes
        pets[index].clothingX = box.minX
        pets[index].clothingY = box.minY
        pets[index].clothingW = box.width
        pets[index].clothingH = box.height
        pets[index].shirtHex = sampledColor(in: texture, yStart: 0, yEnd: 1, fallback: NSColor(hex: pets[index].shirtHex) ?? NSColor(hex: "#78A79F")!).hexString
        save()
        return pets[index]
    }

    @discardableResult
    func updatePaintedHead(id: UUID, strokes: [PaintStroke]) -> PetRecord? {
        guard let index = pets.firstIndex(where: { $0.id == id }),
              let source = NSImage(contentsOf: imageURL(for: pets[index]))?.cgImageValue,
              let result = makePaintedCutout(from: source, strokes: strokes) else { return nil }
        let filename = pets[index].headFilename ?? "\(id.uuidString)-head.png"
        guard writePNG(result.image, to: imagesURL.appendingPathComponent(filename)) else { return nil }
        pets[index].headFilename = filename
        pets[index].headVersion = 6
        pets[index].faceFeatures = detectFacialFeatures(in: result.image)
        pets[index].headMaskStrokes = strokes
        save()
        return pets[index]
    }

    private func cropNormalized(_ image: CGImage, region: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = CGRect(
            x: region.minX * CGFloat(image.width),
            y: (1 - region.maxY) * CGFloat(image.height),
            width: region.width * CGFloat(image.width),
            height: region.height * CGFloat(image.height)
        ).integral.intersection(bounds)
        guard crop.width > 4, crop.height > 4 else { return nil }
        return image.cropping(to: crop)
    }

    private func makePaintMask(for image: CGImage, strokes: [PaintStroke]) -> (CGImage, CGRect)? {
        let sourceW = CGFloat(image.width), sourceH = CGFloat(image.height)
        let scale = min(1, 1280 / max(sourceW, sourceH))
        let width = max(8, Int((sourceW * scale).rounded()))
        let height = max(8, Int((sourceH * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setBlendMode(.copy)
        let shortSide = CGFloat(min(width, height))
        guard let raw = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = context.bytesPerRow

        func draw(_ stroke: PaintStroke, into target: CGContext, gray: CGFloat, close: Bool) {
            let radius = max(1.5, stroke.radius * shortSide)
            target.setStrokeColor(gray: gray, alpha: 1)
            target.setFillColor(gray: gray, alpha: 1)
            target.setLineCap(.round)
            target.setLineJoin(.round)
            target.setBlendMode(.copy)
            target.setLineWidth(radius * 2)
            let first = CGPoint(x: stroke.points[0].x * CGFloat(width), y: (1 - stroke.points[0].y) * CGFloat(height))
            if stroke.points.count == 1 {
                target.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
            } else {
                target.beginPath()
                target.move(to: first)
                for point in stroke.points.dropFirst() {
                    target.addLine(to: CGPoint(x: point.x * CGFloat(width), y: (1 - point.y) * CGFloat(height)))
                }
                if close { target.addLine(to: first); target.closePath() }
                target.strokePath()
            }
        }

        for stroke in strokes where !stroke.points.isEmpty {
            guard stroke.fillsInterior == true, !stroke.erasing, stroke.points.count >= 2 else {
                draw(stroke, into: context, gray: stroke.erasing ? 0 : 1, close: false)
                continue
            }
            guard let boundary = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ), let boundaryRaw = boundary.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            boundary.setFillColor(gray: 0, alpha: 1)
            boundary.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(stroke, into: boundary, gray: 1, close: true)

            // Mark every background pixel reachable from the canvas edge. What
            // remains is the exact closed interior, even when the line crosses
            // itself; separate lobes are filled instead of toggled by winding.
            let boundaryRowBytes = boundary.bytesPerRow
            var outside = [UInt8](repeating: 0, count: width * height)
            var queue = [Int]()
            queue.reserveCapacity(width * 2 + height * 2)
            func enqueue(_ x: Int, _ y: Int) {
                guard x >= 0, x < width, y >= 0, y < height else { return }
                let index = y * width + x
                guard outside[index] == 0, boundaryRaw[y * boundaryRowBytes + x] <= 12 else { return }
                outside[index] = 1
                queue.append(index)
            }
            for x in 0..<width { enqueue(x, 0); enqueue(x, height - 1) }
            for y in 0..<height { enqueue(0, y); enqueue(width - 1, y) }
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]; cursor += 1
                let x = index % width, y = index / width
                enqueue(x - 1, y); enqueue(x + 1, y); enqueue(x, y - 1); enqueue(x, y + 1)
            }
            for y in 0..<height {
                for x in 0..<width where outside[y * width + x] == 0 {
                    raw[y * rowBytes + x] = 255
                }
            }
        }
        guard let mask = context.makeImage() else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where raw[y * rowBytes + x] > 12 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = max(2, Int(shortSide * 0.006))
        minX = max(0, minX - pad); minY = max(0, minY - pad)
        maxX = min(width - 1, maxX + pad); maxY = min(height - 1, maxY + pad)
        // Bitmap rows are top-origin, while Core Image and all persisted crop
        // rectangles are bottom-origin. Converting here keeps the painted mask,
        // the source pixels and the final crop on the exact same area.
        let box = CGRect(
            x: CGFloat(minX) / CGFloat(width), y: 1 - CGFloat(maxY + 1) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
        return (mask, box)
    }

    private func makePaintedCutout(from image: CGImage, strokes: [PaintStroke]) -> (image: CGImage, crop: CGRect)? {
        guard let (maskImage, normalizedCrop) = makePaintMask(for: image, strokes: strokes) else { return nil }
        let source = CIImage(cgImage: image)
        var mask = CIImage(cgImage: maskImage)
        mask = mask.transformed(by: CGAffineTransform(
            scaleX: source.extent.width / mask.extent.width,
            y: source.extent.height / mask.extent.height
        )).cropped(to: source.extent)
        mask = mask
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 0.8])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.75])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.38])
            .cropped(to: source.extent)
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: source.extent)
        let subject = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: mask
        ])
        let expanded = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1.4, source.extent.width / 1000)]).cropped(to: source.extent)
        let outlineColor = CIImage(color: CIColor(red: 0.17, green: 0.15, blue: 0.14, alpha: 0.96)).cropped(to: source.extent)
        let outline = outlineColor.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: expanded
        ])
        let composed = subject.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: outline])
        let crop = CGRect(
            x: normalizedCrop.minX * source.extent.width,
            y: normalizedCrop.minY * source.extent.height,
            width: normalizedCrop.width * source.extent.width,
            height: normalizedCrop.height * source.extent.height
        ).integral.intersection(source.extent)
        guard crop.width > 4, crop.height > 4,
              let output = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(composed, from: crop) else { return nil }
        return (output, normalizedCrop)
    }

    @discardableResult
    func updateCrop(id: UUID, face: CGRect) -> PetRecord? {
        guard let index = pets.firstIndex(where: { $0.id == id }),
              let source = NSImage(contentsOf: imageURL(for: pets[index]))?.cgImageValue else { return nil }
        let safeFace = CGRect(
            x: clamp(face.minX, 0, 0.98),
            y: clamp(face.minY, 0, 0.98),
            width: clamp(face.width, 0.04, 1 - clamp(face.minX, 0, 0.98)),
            height: clamp(face.height, 0.04, 1 - clamp(face.minY, 0, 0.98))
        )
        let filename = pets[index].headFilename ?? "\(id.uuidString)-head.png"
        let destination = imagesURL.appendingPathComponent(filename)
        guard let cutout = makeHeadCutout(from: source, face: safeFace), writePNG(cutout, to: destination) else { return nil }
        pets[index].faceX = safeFace.minX
        pets[index].faceY = safeFace.minY
        pets[index].faceW = safeFace.width
        pets[index].faceH = safeFace.height
        pets[index].headFilename = filename
        pets[index].headVersion = 6
        pets[index].headMaskStrokes = nil
        pets[index].faceFeatures = detectFacialFeatures(in: cutout)
        save()
        return pets[index]
    }

    @discardableResult
    func updateAutomaticHead(id: UUID) -> PetRecord? {
        guard let index = pets.firstIndex(where: { $0.id == id }),
              let source = NSImage(contentsOf: imageURL(for: pets[index]))?.cgImageValue else { return nil }
        let fallback = CGRect(x: pets[index].faceX, y: pets[index].faceY, width: pets[index].faceW, height: pets[index].faceH)
        let face = detectFace(in: source) ?? fallback
        let filename = pets[index].headFilename ?? "\(id.uuidString)-head.png"
        guard let cutout = makeHeadCutout(from: source, face: face),
              writePNG(cutout, to: imagesURL.appendingPathComponent(filename)) else { return nil }
        pets[index].faceX = face.minX
        pets[index].faceY = face.minY
        pets[index].faceW = face.width
        pets[index].faceH = face.height
        pets[index].headFilename = filename
        pets[index].headVersion = 6
        pets[index].headMaskStrokes = nil
        pets[index].faceFeatures = detectFacialFeatures(in: cutout)
        save()
        return pets[index]
    }

    @discardableResult
    func updateFreeformCrop(id: UUID, points: [CGPoint]) -> PetRecord? {
        guard points.count >= 3,
              let index = pets.firstIndex(where: { $0.id == id }),
              let source = NSImage(contentsOf: imageURL(for: pets[index]))?.cgImageValue,
              let cutout = makeFreeformCutout(from: source, points: points) else { return nil }
        let filename = pets[index].headFilename ?? "\(id.uuidString)-head.png"
        guard writePNG(cutout, to: imagesURL.appendingPathComponent(filename)) else { return nil }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minTopY = points.map(\.y).min() ?? 0
        let maxTopY = points.map(\.y).max() ?? 1
        pets[index].faceX = minX
        pets[index].faceY = 1 - maxTopY
        pets[index].faceW = max(0.04, maxX - minX)
        pets[index].faceH = max(0.04, maxTopY - minTopY)
        pets[index].headFilename = filename
        pets[index].headVersion = 3
        pets[index].faceFeatures = detectFacialFeatures(in: cutout)
        save()
        return pets[index]
    }

    private func makeFreeformCutout(from image: CGImage, points: [CGPoint]) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 4, height > 4, points.count >= 3,
              let maskContext = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }
        maskContext.setFillColor(gray: 0, alpha: 1)
        maskContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].x * CGFloat(width), y: (1 - points[0].y) * CGFloat(height)))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * CGFloat(width), y: (1 - point.y) * CGFloat(height)))
        }
        path.closeSubpath()
        maskContext.addPath(path)
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.fillPath()
        guard let maskImage = maskContext.makeImage() else { return nil }

        let source = CIImage(cgImage: image)
        let mask = CIImage(cgImage: maskImage)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.55])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.5])
            .cropped(to: source.extent)
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: source.extent)
        let subject = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: mask
        ])
        let radius = max(1.2, min(3.2, source.extent.width / 1100))
        let expanded = mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius]).cropped(to: source.extent)
        let outlineColor = CIImage(color: CIColor(red: 0.17, green: 0.15, blue: 0.14, alpha: 0.96)).cropped(to: source.extent)
        let outline = outlineColor.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: expanded
        ])
        let composed = subject.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: outline])
        let minX = max(0, points.map(\.x).min() ?? 0)
        let maxX = min(1, points.map(\.x).max() ?? 1)
        let minTopY = max(0, points.map(\.y).min() ?? 0)
        let maxTopY = min(1, points.map(\.y).max() ?? 1)
        let pad = max(3, CGFloat(width) * 0.006)
        let crop = CGRect(
            x: minX * CGFloat(width) - pad,
            y: (1 - maxTopY) * CGFloat(height) - pad,
            width: (maxX - minX) * CGFloat(width) + pad * 2,
            height: (maxTopY - minTopY) * CGFloat(height) + pad * 2
        ).intersection(source.extent)
        guard crop.width > 4, crop.height > 4 else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(composed, from: crop)
    }

    private func detectFace(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
            return nil
        }
        let box = face.boundingBox
        let width = min(0.94, box.width * 1.58)
        let height = min(0.94, box.height * 1.62)
        let centerX = box.midX
        let centerY = box.midY + box.height * 0.10
        let x = clamp(centerX - width / 2, 0.0, 1.0 - width)
        let y = clamp(centerY - height / 2, 0.0, 1.0 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func detectFacialFeatures(in image: CGImage) -> FaceFeatureRecord? {
        let source = CIImage(cgImage: image)
        let gray = CIImage(color: CIColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 1)).cropped(to: source.extent)
        let flattened = source.composited(over: gray)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let input = context.createCGImage(flattened, from: source.extent) else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: input, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
        let box = face.boundingBox
        func center(_ region: VNFaceLandmarkRegion2D?, fallback: CGPoint) -> CGPoint {
            guard let points = region?.normalizedPoints, !points.isEmpty else { return fallback }
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + CGFloat($1.x), y: $0.y + CGFloat($1.y)) }
            let local = CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
            return CGPoint(x: box.minX + local.x * box.width, y: box.minY + local.y * box.height)
        }
        let left = center(face.landmarks?.leftEye, fallback: CGPoint(x: box.minX + box.width * 0.34, y: box.minY + box.height * 0.62))
        let right = center(face.landmarks?.rightEye, fallback: CGPoint(x: box.minX + box.width * 0.66, y: box.minY + box.height * 0.62))
        let mouth = center(face.landmarks?.outerLips, fallback: CGPoint(x: box.midX, y: box.minY + box.height * 0.28))
        return FaceFeatureRecord(leftEye: left, rightEye: right, mouth: mouth)
    }

    private func headCropRect(for face: CGRect) -> CGRect {
        // `detectFace` already expands the real face rectangle by 1.58×/1.62×,
        // which includes hair and enough neck. Extending downward again pulled
        // a large block of torso into the "head" and made the neck look detached.
        let extraX = face.width * 0.05
        let extraTop = face.height * 0.04
        let minX = max(0, face.minX - extraX)
        let maxX = min(1, face.maxX + extraX)
        let minY = max(0, face.minY)
        let maxY = min(1, face.maxY + extraTop)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func makeHeadCutout(from image: CGImage, face: CGRect) -> CGImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first else {
            return nil
        }

        let source = CIImage(cgImage: image)
        var mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        let scaleX = source.extent.width / mask.extent.width
        let scaleY = source.extent.height / mask.extent.height
        mask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        mask = mask
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.65])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.42])
            .cropped(to: source.extent)

        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: source.extent)
        let subject = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: mask
        ])
        let outlineRadius = max(1.4, min(4.0, source.extent.width / 900.0))
        let expandedMask = mask
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: outlineRadius])
            .cropped(to: source.extent)
        let outlineColor = CIImage(color: CIColor(red: 0.17, green: 0.15, blue: 0.14, alpha: 0.96)).cropped(to: source.extent)
        let outline = outlineColor.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: expandedMask
        ])
        let composed = subject.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: outline])

        let pixelW = source.extent.width
        let pixelH = source.extent.height
        let normalizedCrop = headCropRect(for: face)
        var crop = CGRect(
            x: normalizedCrop.minX * pixelW,
            y: normalizedCrop.minY * pixelH,
            width: normalizedCrop.width * pixelW,
            height: normalizedCrop.height * pixelH
        ).intersection(source.extent)
        crop.size.width = min(crop.width, source.extent.maxX - crop.minX)
        crop.size.height = min(crop.height, source.extent.maxY - crop.minY)
        guard crop.width > 4, crop.height > 4 else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(composed, from: crop)
    }

    private func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func sampledColor(in image: CGImage, yStart: CGFloat, yEnd: CGFloat, fallback: NSColor) -> NSColor {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return fallback }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, weight: CGFloat = 0
        let x0 = Int(CGFloat(width) * 0.33)
        let x1 = Int(CGFloat(width) * 0.67)
        let y0 = Int(CGFloat(height) * yStart)
        let y1 = Int(CGFloat(height) * yEnd)
        let xStep = max(1, (x1 - x0) / 18)
        let yStep = max(1, (y1 - y0) / 12)
        for y in stride(from: y0, to: max(y0 + 1, y1), by: yStep) {
            for x in stride(from: x0, to: max(x0 + 1, x1), by: xStep) {
                guard let color = bitmap.colorAt(x: clamp(x, 0, width-1), y: clamp(y, 0, height-1))?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent < 0.18 { continue }
                let maxC = max(color.redComponent, color.greenComponent, color.blueComponent)
                let minC = min(color.redComponent, color.greenComponent, color.blueComponent)
                let brightness = (maxC + minC) / 2
                if brightness > 0.96 || brightness < 0.06 { continue }
                let saturationWeight = 0.65 + (maxC - minC)
                red += color.redComponent * saturationWeight
                green += color.greenComponent * saturationWeight
                blue += color.blueComponent * saturationWeight
                weight += saturationWeight
            }
        }
        guard weight > 2 else { return fallback }
        var result = NSColor(srgbRed: red/weight, green: green/weight, blue: blue/weight, alpha: 1)
        if let rgb = result.usingColorSpace(.sRGB) {
            let luminance = rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114
            if luminance > 0.82 { result = result.mixed(with: fallback, amount: 0.28) }
            if luminance < 0.18 { result = result.mixed(with: .white, amount: 0.16) }
        }
        return result
    }
}

// MARK: - Pet window and animation

enum PetActionMode: String, CaseIterable {
    case dockCrawl, perimeter, dance, hop, mixed

    var title: String {
        switch self {
        case .dockCrawl: return "Dock 爬行"
        case .perimeter: return "沿屏幕四周"
        case .dance: return "站立跳舞"
        case .hop: return "跳来跳去"
        case .mixed: return "随机动作"
        }
    }
}

final class BubbleSettings {
    enum TimingMode: String { case fixed, random }

    private let defaults = UserDefaults.standard
    var mode: TimingMode
    var fixedMinutes: Double
    var randomMinMinutes: Double
    var randomMaxMinutes: Double
    var messages: [String]
    var dragMessages: [String]
    var animationFPS: Int
    var actionMode: PetActionMode
    var faceTrackingEnabled: Bool

    init() {
        mode = TimingMode(rawValue: defaults.string(forKey: "bubble.mode") ?? "random") ?? .random
        fixedMinutes = defaults.object(forKey: "bubble.fixedMinutes") as? Double ?? 2.0
        randomMinMinutes = defaults.object(forKey: "bubble.randomMinMinutes") as? Double ?? 1.0
        randomMaxMinutes = defaults.object(forKey: "bubble.randomMaxMinutes") as? Double ?? 4.0
        messages = defaults.stringArray(forKey: "bubble.messages") ?? ["陪你一会儿呀", "今天也很可爱", "摸摸我嘛", "休息一下吧"]
        dragMessages = defaults.stringArray(forKey: "bubble.dragMessages") ?? ["呀！轻一点～", "我要飞走啦！", "放我下来嘛", "抓稳我哦！"]
        animationFPS = defaults.object(forKey: "animation.fps") as? Int ?? 30
        actionMode = PetActionMode(rawValue: defaults.string(forKey: "animation.actionMode") ?? "mixed") ?? .mixed
        faceTrackingEnabled = defaults.object(forKey: "expression.faceTracking") as? Bool ?? true
    }

    func save() {
        defaults.set(mode.rawValue, forKey: "bubble.mode")
        defaults.set(fixedMinutes, forKey: "bubble.fixedMinutes")
        defaults.set(randomMinMinutes, forKey: "bubble.randomMinMinutes")
        defaults.set(randomMaxMinutes, forKey: "bubble.randomMaxMinutes")
        defaults.set(messages, forKey: "bubble.messages")
        defaults.set(dragMessages, forKey: "bubble.dragMessages")
        defaults.set(animationFPS, forKey: "animation.fps")
        defaults.set(actionMode.rawValue, forKey: "animation.actionMode")
        defaults.set(faceTrackingEnabled, forKey: "expression.faceTracking")
    }

    func nextDelay() -> TimeInterval {
        if mode == .fixed { return max(6, fixedMinutes * 60) }
        let low = max(6, randomMinMinutes * 60)
        let high = max(low, randomMaxMinutes * 60)
        return Double.random(in: low...high)
    }

    func randomMessage(isDragging: Bool) -> String {
        let pool = isDragging ? dragMessages : messages
        return pool.randomElement() ?? (isDragging ? "轻一点呀～" : "陪陪我嘛")
    }
}

enum CrawlEdge {
    case bottom, right, top, left

    var angle: CGFloat {
        switch self {
        case .bottom: return 0
        case .right: return .pi / 2
        case .top: return .pi
        case .left: return -.pi / 2
        }
    }
}

enum PetMotion {
    case walking, dragging, falling, landed, climbing, reacting
}

final class PetWindow: NSPanel {
    let record: PetRecord
    let portrait: NSImage
    let headPortrait: NSImage?
    let clothingTexture: NSImage?
    let portraitCG: CGImage?
    let headCG: CGImage?
    let clothingTextureCG: CGImage?
    let bubbleSettings: BubbleSettings
    private(set) var motion: PetMotion = .walking
    private(set) var bubbleText: String?
    var phase: CGFloat = 0
    var direction: CGFloat = 1
    private(set) var crawlEdge: CrawlEdge = .bottom
    private(set) var activeAction: PetActionMode = .dockCrawl
    var paused = false
    private var velocity = CGPoint.zero
    private var dragOffset = CGPoint.zero
    private var lastMouse = CGPoint.zero
    private var lastMouseTime: TimeInterval = 0
    private var dragDistance: CGFloat = 0
    private var dragStartEdge: CrawlEdge = .bottom
    private var reactionReturnsToTrack = false
    private var stateTime: TimeInterval = 0
    private var bounceCount = 0
    private var releasedFromY: CGFloat = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var bubbleUntil: TimeInterval = 0
    private var nextBubbleAt: TimeInterval = 0
    private var logicalOrigin = CGPoint.zero
    private var nextActionChange: TimeInterval = 0
    private var observedMode: PetActionMode?

    init(record: PetRecord, imageURL: URL, headURL: URL?, clothingTextureURL: URL?, bubbleSettings: BubbleSettings) {
        self.record = record
        let portrait = NSImage(contentsOf: imageURL) ?? NSImage(size: NSSize(width: 200, height: 200))
        let headPortrait = headURL.flatMap { NSImage(contentsOf: $0) }
        let clothingTexture = clothingTextureURL.flatMap { NSImage(contentsOf: $0) }
        self.portrait = portrait
        self.headPortrait = headPortrait
        self.clothingTexture = clothingTexture
        self.portraitCG = portrait.cgImageValue
        self.headCG = headPortrait?.cgImageValue
        self.clothingTextureCG = clothingTexture?.cgImageValue
        self.bubbleSettings = bubbleSettings
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 214, height: 214),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        contentView = PetView(petWindow: self)

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let seed = CGFloat(abs(record.id.uuidString.hashValue % 1000)) / 1000
        let full = screen.frame
        let x = full.minX + 20 + seed * max(40, full.width - frame.width - 40)
        logicalOrigin = NSPoint(x: x, y: perchY(on: screen))
        setFrameOrigin(logicalOrigin)
        direction = seed > 0.5 ? -1 : 1
        activeAction = bubbleSettings.actionMode == .mixed ? .dockCrawl : bubbleSettings.actionMode
        nextActionChange = ProcessInfo.processInfo.systemUptime + 5
        resetBubbleSchedule()
    }

    var petView: PetView? { contentView as? PetView }

    private func currentScreen() -> NSScreen {
        screen ?? NSScreen.main ?? NSScreen.screens.first!
    }

    private func perchY(on screen: NSScreen) -> CGFloat {
        // Sit directly on the top edge of the bottom Dock. visibleFrame.minY is
        // the Dock's upper boundary when the Dock is at the bottom of the Mac.
        let full = screen.frame
        let visible = screen.visibleFrame
        let bottomGap = visible.minY - full.minY
        return bottomGap > 8 ? visible.minY - 9 : full.minY + 4
    }

    private func floorY(on screen: NSScreen) -> CGFloat {
        perchY(on: screen)
    }

    private func applyOrigin(_ origin: CGPoint) {
        logicalOrigin = origin
        setFrameOrigin(NSPoint(x: origin.x.rounded(.down), y: origin.y.rounded(.down)))
    }

    func resetAnimationClock() {
        lastTick = ProcessInfo.processInfo.systemUptime
    }

    func beginDrag() {
        guard !paused else { return }
        let mouse = NSEvent.mouseLocation
        dragOffset = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        lastMouse = mouse
        lastMouseTime = ProcessInfo.processInfo.systemUptime
        dragDistance = 0
        logicalOrigin = frame.origin
        dragStartEdge = crawlEdge
        reactionReturnsToTrack = false
        motion = .dragging
        stateTime = 0
        showBubble(bubbleSettings.randomMessage(isDragging: true), duration: 2.5)
        NSCursor.closedHand.push()
    }

    func continueDrag() {
        guard motion == .dragging else { return }
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0.008, now - lastMouseTime)
        velocity = CGPoint(
            x: clamp((mouse.x - lastMouse.x) / CGFloat(dt), -900, 900),
            y: clamp((mouse.y - lastMouse.y) / CGFloat(dt), -900, 900)
        )
        dragDistance += hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y)
        if dragDistance >= 7 { crawlEdge = .bottom }
        lastMouse = mouse
        lastMouseTime = now
        applyOrigin(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
        petView?.needsDisplay = true
    }

    func endDrag() {
        guard motion == .dragging else { return }
        NSCursor.pop()
        if dragDistance < 7 {
            crawlEdge = dragStartEdge
            reactionReturnsToTrack = true
            react()
            return
        }
        releasedFromY = frame.minY
        velocity.x *= 0.12
        velocity.y *= 0.10
        crawlEdge = .bottom
        motion = .falling
        bounceCount = 0
        stateTime = 0
        reactionReturnsToTrack = false
    }

    func react() {
        motion = .reacting
        stateTime = 0
        velocity = .zero
    }

    func resetBubbleSchedule() {
        nextBubbleAt = ProcessInfo.processInfo.systemUptime + bubbleSettings.nextDelay()
    }

    private func showBubble(_ text: String, duration: TimeInterval) {
        bubbleText = text
        bubbleUntil = ProcessInfo.processInfo.systemUptime + duration
        petView?.needsDisplay = true
    }

    private func prepareAction(_ action: PetActionMode, on screen: NSScreen) {
        activeAction = action
        let frameBounds = screen.frame
        var origin = logicalOrigin
        if action == .perimeter {
            if crawlEdge != .bottom {
                crawlEdge = .bottom
                origin.y = perchY(on: screen)
            }
            origin.x = clamp(origin.x, frameBounds.minX + 4, frameBounds.maxX - frame.width - 4)
            direction = 1
        } else {
            crawlEdge = .bottom
            origin.y = perchY(on: screen)
            origin.x = clamp(origin.x, frameBounds.minX + 4, frameBounds.maxX - frame.width - 4)
        }
        applyOrigin(origin)
    }

    private func updateSelectedAction(now: TimeInterval, screen: NSScreen) {
        let selected = bubbleSettings.actionMode
        if observedMode != selected {
            observedMode = selected
            let initial = selected == .mixed ? PetActionMode.dockCrawl : selected
            prepareAction(initial, on: screen)
            nextActionChange = now + Double.random(in: 5...9)
        }
        guard selected == .mixed, now >= nextActionChange, motion == .walking else { return }
        let choices: [PetActionMode] = [.dockCrawl, .perimeter, .dance, .hop]
        let next = choices.filter { $0 != activeAction }.randomElement() ?? .dockCrawl
        prepareAction(next, on: screen)
        nextActionChange = now + Double.random(in: 5...10)
    }

    private func advancePerimeter(origin: inout CGPoint, screen: NSScreen, distance: CGFloat) {
        let full = screen.frame
        let left = full.minX + 4
        let right = full.maxX - frame.width - 4
        let bottom = perchY(on: screen)
        let top = full.maxY - frame.height - 4
        var remaining = max(0, distance)
        var cornerTransitions = 0
        while remaining > 0.0001, cornerTransitions < 8 {
            let previousEdge = crawlEdge
            switch crawlEdge {
            case .bottom:
                let step = min(remaining, max(0, right - origin.x))
                origin.x += step; origin.y = bottom; remaining -= step
                if right - origin.x < 0.001 { crawlEdge = .right; origin.x = right }
            case .right:
                let step = min(remaining, max(0, top - origin.y))
                origin.y += step; origin.x = right; remaining -= step
                if top - origin.y < 0.001 { crawlEdge = .top; origin.y = top }
            case .top:
                let step = min(remaining, max(0, origin.x - left))
                origin.x -= step; origin.y = top; remaining -= step
                if origin.x - left < 0.001 { crawlEdge = .left; origin.x = left }
            case .left:
                let step = min(remaining, max(0, origin.y - bottom))
                origin.y -= step; origin.x = left; remaining -= step
                if origin.y - bottom < 0.001 { crawlEdge = .bottom; origin.y = bottom }
            }
            if crawlEdge != previousEdge { cornerTransitions += 1 }
        }
        direction = 1
    }

    func tick(globalPaused: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        var dt = CGFloat(now - lastTick)
        lastTick = now
        dt = clamp(dt, 0.001, 0.06)
        if bubbleText != nil, now >= bubbleUntil { bubbleText = nil }
        if globalPaused || paused {
            petView?.needsDisplay = true
            return
        }
        phase += dt * (motion == .dragging ? 15 : 9)
        if now >= nextBubbleAt, motion != .dragging, motion != .falling {
            showBubble(bubbleSettings.randomMessage(isDragging: false), duration: 3.2)
            resetBubbleSchedule()
        }
        stateTime += TimeInterval(dt)
        let activeScreen = currentScreen()
        let visible = activeScreen.frame
        updateSelectedAction(now: now, screen: activeScreen)
        var origin = logicalOrigin

        switch motion {
        case .walking:
            switch activeAction {
            case .perimeter:
                advancePerimeter(origin: &origin, screen: activeScreen, distance: 48 * dt)
            case .dockCrawl:
                crawlEdge = .bottom
                origin.x += direction * 48 * dt
                if origin.x < visible.minX + 4 {
                    origin.x = visible.minX + 4
                    direction = 1
                } else if origin.x > visible.maxX - frame.width - 4 {
                    origin.x = visible.maxX - frame.width - 4
                    direction = -1
                }
                origin.y = perchY(on: activeScreen) + sin(phase * 1.4) * 1.2
            case .dance:
                crawlEdge = .bottom
                origin.y = perchY(on: activeScreen)
            case .hop:
                crawlEdge = .bottom
                origin.x += direction * 20 * dt
                if origin.x < visible.minX + 4 { origin.x = visible.minX + 4; direction = 1 }
                if origin.x > visible.maxX - frame.width - 4 { origin.x = visible.maxX - frame.width - 4; direction = -1 }
                origin.y = perchY(on: activeScreen) + abs(sin(phase * 0.62)) * 27
            case .mixed:
                break
            }
            applyOrigin(origin)

        case .falling:
            velocity.y -= 860 * dt
            origin.x += velocity.x * dt
            origin.y += velocity.y * dt
            if origin.x < visible.minX {
                origin.x = visible.minX
                velocity.x = abs(velocity.x) * 0.55
            } else if origin.x > visible.maxX - frame.width {
                origin.x = visible.maxX - frame.width
                velocity.x = -abs(velocity.x) * 0.55
            }
            if origin.y <= floorY(on: activeScreen) {
                origin.y = floorY(on: activeScreen)
                bounceCount += 1
                if bounceCount == 1 && releasedFromY - origin.y > 150 {
                    velocity.y = max(105, abs(velocity.y) * 0.22)
                    velocity.x *= 0.55
                } else {
                    velocity = .zero
                    motion = .landed
                    stateTime = 0
                }
            }
            applyOrigin(origin)

        case .landed:
            if stateTime > 1.05 {
                motion = .walking
                stateTime = 0
                logicalOrigin = frame.origin
            }

        case .climbing:
            origin.y += 170 * dt
            origin.x += sin(phase * 2.1) * 13 * dt
            let target = perchY(on: activeScreen)
            if origin.y >= target {
                origin.y = target
                motion = .walking
                stateTime = 0
            }
            applyOrigin(origin)

        case .reacting:
            if stateTime > 0.95 {
                let target = perchY(on: activeScreen)
                if reactionReturnsToTrack {
                    motion = .walking
                    reactionReturnsToTrack = false
                } else {
                    motion = abs(origin.y - target) > 12 ? .falling : .walking
                }
                stateTime = 0
            }

        case .dragging:
            break
        }
        petView?.needsDisplay = true
    }
}

final class PetView: NSView {
    weak var petWindow: PetWindow?
    private var mouseIsDown = false

    init(petWindow: PetWindow) {
        self.petWindow = petWindow
        super.init(frame: NSRect(x: 0, y: 0, width: 214, height: 214))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let edge = petWindow?.crawlEdge ?? .bottom
        let characterArea: CGRect
        switch edge {
        case .bottom: characterArea = CGRect(x: bounds.midX - 76, y: 0, width: 152, height: 130)
        case .top: characterArea = CGRect(x: bounds.midX - 76, y: bounds.maxY - 130, width: 152, height: 130)
        case .left: characterArea = CGRect(x: 0, y: bounds.midY - 76, width: 130, height: 152)
        case .right: characterArea = CGRect(x: bounds.maxX - 130, y: bounds.midY - 76, width: 130, height: 152)
        }
        let bubbleArea = CGRect(x: 4, y: 154, width: bounds.width - 8, height: 56)
        guard characterArea.contains(point) || (petWindow?.bubbleText != nil && bubbleArea.contains(point)) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        mouseIsDown = true
        petWindow?.beginDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseIsDown else { return }
        petWindow?.continueDrag()
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseIsDown else { return }
        mouseIsDown = false
        petWindow?.endDrag()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window = petWindow, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let state = window.motion
        let phase = window.phase
        let crawlAction = window.activeAction == .dockCrawl || window.activeAction == .perimeter
        let moving = (state == .walking && crawlAction) || state == .climbing
        let crawl = moving ? sin(phase) : 0
        let dragWiggle = state == .dragging ? sin(phase * 1.8) : 0
        let bodyBob = moving ? abs(sin(phase)) * 2.8 : 0

        context.saveGState()
        let anchor: CGPoint
        switch window.crawlEdge {
        case .bottom: anchor = CGPoint(x: bounds.midX, y: 4)
        case .right: anchor = CGPoint(x: bounds.maxX - 4, y: bounds.midY)
        case .top: anchor = CGPoint(x: bounds.midX, y: bounds.maxY - 4)
        case .left: anchor = CGPoint(x: 4, y: bounds.midY)
        }
        context.translateBy(x: anchor.x, y: anchor.y)
        context.rotate(by: window.crawlEdge.angle)
        context.scaleBy(x: window.direction, y: 1)
        if state == .dragging { context.rotate(by: dragWiggle * 0.11) }
        if state == .falling { context.rotate(by: sin(phase * 1.3) * 0.18) }

        if state == .walking && (window.activeAction == .dance || window.activeAction == .hop) {
            drawUprightPose(window: window, phase: phase, hopping: window.activeAction == .hop, context: context)
            context.restoreGState()
            if let text = window.bubbleText { drawSpeechBubble(text, direction: window.direction, context: context) }
            return
        }

        // Long, low contact shadow: the character is on all fours on the Dock.
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(state == .falling ? 0.04 : 0.13).cgColor)
        context.scaleBy(x: 1, y: 0.30)
        context.fillEllipse(in: CGRect(x: -57, y: 3, width: 119, height: 18))
        context.restoreGState()

        let ink = NSColor(hex: "#2C2927")!
        let shirt = NSColor(hex: window.record.shirtHex) ?? NSColor(hex: "#78A79F")!
        let pants = NSColor(hex: window.record.pantsHex) ?? NSColor(hex: "#475E64")!
        let cream = NSColor(hex: "#FFF8E8")!

        let frontLift = max(0, crawl) * 6
        let backLift = max(0, -crawl) * 6
        let reach = crawl * 9
        let struggle = state == .dragging ? sin(phase * 2.4) * 11 : 0
        let airborne = state == .falling

        var farRear = CGPoint(x: -39 + reach * 0.65, y: 11 + backLift)
        var farFront = CGPoint(x: 25 - reach * 0.75, y: 12 + frontLift)
        var nearRear = CGPoint(x: -26 - reach * 0.72, y: 9 + frontLift)
        var nearFront = CGPoint(x: 43 + reach * 0.82, y: 9 + backLift)
        if state == .dragging || airborne {
            farRear = CGPoint(x: -47, y: 42 + struggle)
            farFront = CGPoint(x: 43, y: 47 - struggle)
            nearRear = CGPoint(x: -34, y: 56 - struggle)
            nearFront = CGPoint(x: 52, y: 58 + struggle)
        }

        let rearHip = CGPoint(x: -20, y: 35 + bodyBob)
        let frontShoulder = CGPoint(x: 15, y: 37 + bodyBob)
        drawLine(context, from: rearHip, to: farRear, width: 10, color: ink)
        drawLine(context, from: rearHip, to: farRear, width: 6.3, color: pants.mixed(with: .white, amount: 0.08))
        drawShoe(at: farRear, direction: -1, ink: ink, context: context)
        drawLine(context, from: frontShoulder, to: farFront, width: 9, color: ink)
        drawLine(context, from: frontShoulder, to: farFront, width: 5.6, color: shirt.mixed(with: .white, amount: 0.14))
        drawHand(at: farFront, ink: ink, context: context)

        // Low horizontal torso with an organic outline and a little squash/stretch.
        context.saveGState()
        context.translateBy(x: 0, y: bodyBob)
        context.rotate(by: moving ? crawl * 0.025 : 0)
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -35, y: 37))
        body.addCurve(to: CGPoint(x: -17, y: 60), control1: CGPoint(x: -36, y: 49), control2: CGPoint(x: -29, y: 58))
        body.addCurve(to: CGPoint(x: 29, y: 53), control1: CGPoint(x: -3, y: 62), control2: CGPoint(x: 23, y: 61))
        body.addCurve(to: CGPoint(x: 24, y: 35), control1: CGPoint(x: 34, y: 46), control2: CGPoint(x: 31, y: 38))
        body.addCurve(to: CGPoint(x: -35, y: 37), control1: CGPoint(x: 6, y: 29), control2: CGPoint(x: -24, y: 28))
        context.addPath(body)
        context.setFillColor(ink.cgColor)
        context.fillPath()
        context.saveGState()
        context.translateBy(x: 0, y: 1)
        context.scaleBy(x: 0.91, y: 0.86)
        context.addPath(body)
        context.clip()
        let shirtArea = CGRect(x: -39, y: 27, width: 76, height: 40)
        let hasShirtTexture: Bool
        if let texture = window.clothingTextureCG {
            hasShirtTexture = drawTextureImage(texture, in: shirtArea, context: context)
        } else if let portrait = window.portraitCG {
            hasShirtTexture = drawClothingTexture(portrait, record: window.record, lowerGarment: false, in: shirtArea, context: context)
        } else {
            hasShirtTexture = false
        }
        if hasShirtTexture {
            context.setFillColor(shirt.withAlphaComponent(0.10).cgColor)
            context.fill(shirtArea)
            if let shade = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [NSColor.black.withAlphaComponent(0.16).cgColor, NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.10).cgColor] as CFArray,
                locations: [0, 0.52, 1]
            ) {
                context.drawLinearGradient(shade, start: CGPoint(x: shirtArea.minX, y: shirtArea.midY), end: CGPoint(x: shirtArea.maxX, y: shirtArea.midY), options: [])
            }
        } else {
            context.setFillColor(shirt.cgColor)
            context.fill(shirtArea)
        }
        context.restoreGState()

        // Pants patch uses the lower-garment pixels from the original photo.
        let pantsPatch = CGPath(roundedRect: CGRect(x: -31, y: 32, width: 20, height: 24), cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.saveGState()
        context.addPath(pantsPatch)
        context.clip()
        let pantsArea = CGRect(x: -33, y: 30, width: 25, height: 28)
        if let portrait = window.portraitCG, drawClothingTexture(portrait, record: window.record, lowerGarment: true, in: pantsArea, context: context) {
            context.setFillColor(pants.withAlphaComponent(0.08).cgColor)
            context.fill(pantsArea)
        } else {
            context.setFillColor(pants.cgColor)
            context.fill(pantsArea)
        }
        context.restoreGState()
        drawLine(context, from: CGPoint(x: -10, y: 53), to: CGPoint(x: -8, y: 35), width: 2.1, color: cream.withAlphaComponent(0.72))
        drawLine(context, from: CGPoint(x: 6, y: 53), to: CGPoint(x: 14, y: 50), width: 1.8, color: cream.withAlphaComponent(0.72))
        context.restoreGState()

        // Sloped shoulder/collar under the photo cutout. The freely selected
        // neck overlaps this wedge, producing a soft diagonal joint instead of
        // a rigid horizontal or vertical skin-coloured bar.
        let collar = CGMutablePath()
        collar.move(to: CGPoint(x: 10, y: 48 + bodyBob))
        collar.addCurve(to: CGPoint(x: 24, y: 63 + bodyBob * 0.45), control1: CGPoint(x: 14, y: 57 + bodyBob), control2: CGPoint(x: 19, y: 62 + bodyBob * 0.6))
        collar.addCurve(to: CGPoint(x: 35, y: 51 + bodyBob * 0.35), control1: CGPoint(x: 30, y: 65 + bodyBob * 0.4), control2: CGPoint(x: 36, y: 59 + bodyBob * 0.4))
        collar.addCurve(to: CGPoint(x: 10, y: 48 + bodyBob), control1: CGPoint(x: 29, y: 45 + bodyBob), control2: CGPoint(x: 18, y: 44 + bodyBob))
        context.addPath(collar)
        context.setFillColor(ink.cgColor)
        context.fillPath()
        context.saveGState()
        context.translateBy(x: 0, y: 1)
        context.scaleBy(x: 0.88, y: 0.84)
        context.addPath(collar)
        context.setFillColor(shirt.cgColor)
        context.fillPath()
        context.restoreGState()

        // Near pair crosses the far pair on each half-cycle: unmistakable crawl.
        drawLine(context, from: rearHip, to: nearRear, width: 11, color: ink)
        drawLine(context, from: rearHip, to: nearRear, width: 6.8, color: pants)
        drawShoe(at: nearRear, direction: -1, ink: ink, context: context)
        drawLine(context, from: frontShoulder, to: nearFront, width: 10, color: ink)
        drawLine(context, from: frontShoulder, to: nearFront, width: 6.2, color: shirt)
        drawHand(at: nearFront, ink: ink, context: context)

        // The head leads the crawl and nods opposite the torso. The generated PNG
        // is a transparent person silhouette, so there is no rounded-rectangle crop.
        let headCenter = CGPoint(x: 26, y: 57 + bodyBob * 0.42)
        let headScale: CGFloat = state == .falling ? 1.05 : (state == .landed ? 0.94 : 1)
        context.saveGState()
        context.translateBy(x: headCenter.x, y: headCenter.y)
        context.rotate(by: moving ? (-0.10 - crawl * 0.045) : (-0.08 + dragWiggle * 0.035))
        context.scaleBy(x: headScale, y: state == .landed ? 0.90 : 1)
        let headRect = CGRect(x: -36, y: -10, width: 72, height: 84)
        var fittedHeadRect = headRect
        if let head = window.headCG {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 2.5, color: NSColor.black.withAlphaComponent(0.22).cgColor)
            context.interpolationQuality = .high
            // Respect the complete transparent cutout and pin its real lower
            // edge into the collar. This avoids a second visual crop and keeps
            // a painted neck connected to the body regardless of aspect ratio.
            let fitted = aspectFitAnchored(for: head, maxSize: headRect.size, bottomY: headRect.minY)
            fittedHeadRect = fitted
            context.draw(head, in: fitted)
            context.restoreGState()
        } else {
            let outline = CGPath(roundedRect: headRect.insetBy(dx: -2.5, dy: -2.5), cornerWidth: 24, cornerHeight: 24, transform: nil)
            context.addPath(outline)
            context.setFillColor(ink.cgColor)
            context.fillPath()
            let clip = CGPath(roundedRect: headRect, cornerWidth: 22, cornerHeight: 22, transform: nil)
            context.addPath(clip)
            context.clip()
            drawPortrait(window.portrait, record: window.record, in: headRect, context: context)
        }
        drawExpression(state: state, action: window.activeAction, phase: phase, headRect: fittedHeadRect, record: window.record, tracking: window.bubbleSettings.faceTrackingEnabled, context: context)
        if window.bubbleText != nil {
            drawOpenMouth(phase: phase, headRect: fittedHeadRect, record: window.record, tracking: window.bubbleSettings.faceTrackingEnabled, context: context)
        }
        context.restoreGState()
        context.restoreGState()

        if let text = window.bubbleText {
            drawSpeechBubble(text, direction: window.direction, context: context)
        }
    }

    private func drawUprightPose(window: PetWindow, phase: CGFloat, hopping: Bool, context: CGContext) {
        let ink = NSColor(hex: "#2C2927")!
        let shirt = NSColor(hex: window.record.shirtHex) ?? NSColor(hex: "#78A79F")!
        let pants = NSColor(hex: window.record.pantsHex) ?? NSColor(hex: "#475E64")!
        let beat = sin(phase * (hopping ? 0.9 : 1.25))
        let lift = hopping ? abs(sin(phase * 0.62)) : 0

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.14 - lift * 0.07).cgColor)
        context.scaleBy(x: 1 - lift * 0.24, y: 0.28)
        context.fillEllipse(in: CGRect(x: -38, y: 4, width: 76, height: 18))
        context.restoreGState()

        context.saveGState()
        context.translateBy(x: hopping ? 0 : beat * 3, y: hopping ? 3 : abs(beat) * 1.5)
        context.rotate(by: hopping ? beat * 0.025 : beat * 0.075)

        let hipY: CGFloat = 38
        let kneeLift = hopping ? lift * 13 : 0
        let leftFoot = CGPoint(x: -16 - (hopping ? beat * 5 : 0), y: 9 + kneeLift)
        let rightFoot = CGPoint(x: 16 + (hopping ? beat * 5 : 0), y: 9 + kneeLift * 0.72)
        drawLine(context, from: CGPoint(x: -10, y: hipY), to: leftFoot, width: 10, color: ink)
        drawLine(context, from: CGPoint(x: -10, y: hipY), to: leftFoot, width: 6, color: pants)
        drawLine(context, from: CGPoint(x: 10, y: hipY), to: rightFoot, width: 10, color: ink)
        drawLine(context, from: CGPoint(x: 10, y: hipY), to: rightFoot, width: 6, color: pants.mixed(with: .white, amount: 0.06))
        drawShoe(at: leftFoot, direction: -1, ink: ink, context: context)
        drawShoe(at: rightFoot, direction: 1, ink: ink, context: context)

        let torso = CGPath(roundedRect: CGRect(x: -24, y: 35, width: 48, height: 52), cornerWidth: 17, cornerHeight: 17, transform: nil)
        context.addPath(torso); context.setFillColor(ink.cgColor); context.fillPath()
        context.saveGState()
        context.addPath(CGPath(roundedRect: CGRect(x: -21, y: 38, width: 42, height: 47), cornerWidth: 15, cornerHeight: 15, transform: nil))
        context.clip()
        let torsoArea = CGRect(x: -23, y: 36, width: 46, height: 51)
        let textured: Bool
        if let texture = window.clothingTextureCG {
            textured = drawTextureImage(texture, in: torsoArea, context: context)
        } else if let portrait = window.portraitCG {
            textured = drawClothingTexture(portrait, record: window.record, lowerGarment: false, in: torsoArea, context: context)
        } else {
            textured = false
        }
        if !textured { context.setFillColor(shirt.cgColor); context.fill(torsoArea) }
        if let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.black.withAlphaComponent(0.15).cgColor, NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.10).cgColor] as CFArray, locations: [0, 0.55, 1]) {
            context.drawLinearGradient(shade, start: CGPoint(x: torsoArea.minX, y: torsoArea.midY), end: CGPoint(x: torsoArea.maxX, y: torsoArea.midY), options: [])
        }
        context.restoreGState()

        let shoulderY: CGFloat = 73
        let leftHand: CGPoint
        let rightHand: CGPoint
        if hopping {
            leftHand = CGPoint(x: -34, y: 98 + beat * 7)
            rightHand = CGPoint(x: 34, y: 98 - beat * 7)
        } else {
            leftHand = CGPoint(x: -42, y: 76 + beat * 18)
            rightHand = CGPoint(x: 42, y: 76 - beat * 18)
        }
        drawLine(context, from: CGPoint(x: -19, y: shoulderY), to: leftHand, width: 9, color: ink)
        drawLine(context, from: CGPoint(x: -19, y: shoulderY), to: leftHand, width: 5.5, color: shirt)
        drawLine(context, from: CGPoint(x: 19, y: shoulderY), to: rightHand, width: 9, color: ink)
        drawLine(context, from: CGPoint(x: 19, y: shoulderY), to: rightHand, width: 5.5, color: shirt)
        drawHand(at: leftHand, ink: ink, context: context); drawHand(at: rightHand, ink: ink, context: context)

        context.saveGState()
        context.translateBy(x: 0, y: 112)
        context.rotate(by: -beat * 0.055)
        let headRect = CGRect(x: -37, y: -28, width: 74, height: 84)
        var fitted = headRect
        if let head = window.headCG {
            fitted = aspectFitAnchored(for: head, maxSize: headRect.size, bottomY: headRect.minY)
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.4, color: NSColor.black.withAlphaComponent(0.22).cgColor)
            context.draw(head, in: fitted)
        } else {
            context.addPath(CGPath(roundedRect: headRect, cornerWidth: 22, cornerHeight: 22, transform: nil)); context.clip()
            drawPortrait(window.portrait, record: window.record, in: headRect, context: context)
        }
        drawExpression(state: window.motion, action: window.activeAction, phase: phase, headRect: fitted, record: window.record, tracking: window.bubbleSettings.faceTrackingEnabled, context: context)
        if window.bubbleText != nil {
            drawOpenMouth(phase: phase, headRect: fitted, record: window.record, tracking: window.bubbleSettings.faceTrackingEnabled, context: context)
        }
        context.restoreGState()
        context.restoreGState()
    }

    private func facialPoints(record: PetRecord, in rect: CGRect, tracking: Bool) -> (leftEye: CGPoint, rightEye: CGPoint, mouth: CGPoint) {
        let defaults = (
            CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.62),
            CGPoint(x: rect.minX + rect.width * 0.66, y: rect.minY + rect.height * 0.62),
            CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.31)
        )
        guard tracking, let features = record.faceFeatures else { return defaults }
        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + clamp(value.x, 0, 1) * rect.width, y: rect.minY + clamp(value.y, 0, 1) * rect.height)
        }
        return (point(features.leftEye), point(features.rightEye), point(features.mouth))
    }

    private func drawOpenMouth(phase: CGFloat, headRect: CGRect, record: PetRecord, tracking: Bool, context: CGContext) {
        let ink = NSColor(hex: "#2C2927")!
        let center = facialPoints(record: record, in: headRect, tracking: tracking).mouth
        let height = max(5, headRect.height * (0.10 + abs(sin(phase * 1.7)) * 0.045))
        let width = max(7, headRect.width * 0.18)
        let mouth = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        context.setFillColor(ink.withAlphaComponent(0.92).cgColor)
        context.fillEllipse(in: mouth)
        context.setFillColor(NSColor(hex: "#F08B91")!.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - width * 0.31, y: center.y - height * 0.22, width: width * 0.62, height: max(2, height * 0.34)))
    }

    private func drawSpeechBubble(_ text: String, direction: CGFloat, context: CGContext) {
        let width: CGFloat = 132
        let height: CGFloat = 38
        let rawX = direction > 0 ? bounds.midX - 86 : bounds.midX - 46
        let x = clamp(rawX, 5, bounds.width - width - 5)
        let rect = CGRect(x: x, y: 166, width: width, height: height)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        let bubble = CGPath(roundedRect: rect, cornerWidth: 13, cornerHeight: 13, transform: nil)
        context.addPath(bubble)
        context.setFillColor(NSColor(hex: "#FFFDF7")!.withAlphaComponent(0.97).cgColor)
        context.fillPath()
        context.restoreGState()

        context.addPath(CGPath(roundedRect: rect, cornerWidth: 13, cornerHeight: 13, transform: nil))
        context.setStrokeColor(NSColor(hex: "#3C3935")!.withAlphaComponent(0.72).cgColor)
        context.setLineWidth(1.5)
        context.strokePath()

        let tipX = bounds.midX + direction * 27
        let baseX = clamp(tipX - direction * 7, rect.minX + 18, rect.maxX - 18)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: baseX - 7, y: rect.minY + 1))
        tail.addLine(to: CGPoint(x: tipX, y: 154))
        tail.addLine(to: CGPoint(x: baseX + 7, y: rect.minY + 1))
        tail.closeSubpath()
        context.addPath(tail)
        context.setFillColor(NSColor(hex: "#FFFDF7")!.cgColor)
        context.fillPath()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect.insetBy(dx: 10, dy: 10),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor(hex: "#393632")!,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func aspectFitAnchored(for image: CGImage, maxSize: CGSize, bottomY: CGFloat) -> CGRect {
        let scale = min(maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: -size.width / 2, y: bottomY, width: size.width, height: size.height)
    }

    @discardableResult
    private func drawTextureImage(_ cg: CGImage, in rect: CGRect, context: CGContext) -> Bool {
        let scale = max(rect.width / CGFloat(cg.width), rect.height / CGFloat(cg.height))
        let size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        context.saveGState(); context.interpolationQuality = .high; context.draw(cg, in: target); context.restoreGState()
        return true
    }

    @discardableResult
    private func drawClothingTexture(_ cg: CGImage, record: PetRecord, lowerGarment: Bool, in rect: CGRect, context: CGContext) -> Bool {
        let faceX = CGFloat(record.faceX)
        let faceY = CGFloat(record.faceY)
        let faceW = CGFloat(record.faceW)
        let faceH = CGFloat(record.faceH)
        let centerX = faceX + faceW / 2
        let regionWidth: CGFloat
        let maxY: CGFloat
        let minY: CGFloat
        if lowerGarment {
            regionWidth = min(0.70, max(0.16, faceW * 1.28))
            maxY = max(0.06, faceY - faceH * 0.58)
            minY = max(0, maxY - faceH * 0.54)
        } else if record.clothingX != nil, let y = record.clothingY,
                  let width = record.clothingW, let height = record.clothingH,
                  width > 0.03, height > 0.03 {
            regionWidth = CGFloat(width)
            maxY = CGFloat(y + height)
            minY = CGFloat(y)
        } else {
            regionWidth = min(0.62, max(0.16, faceW * 1.22))
            let height = min(0.32, max(0.10, faceH * 0.62))
            maxY = clamp(faceY + faceH * 0.04, height, 1)
            minY = maxY - height
        }
        guard maxY - minY > 0.045 else { return false }
        let regionX: CGFloat
        if !lowerGarment, let x = record.clothingX { regionX = CGFloat(x) }
        else { regionX = clamp(centerX - regionWidth / 2, 0, 1 - regionWidth) }
        let pixelW = CGFloat(cg.width)
        let pixelH = CGFloat(cg.height)
        let crop = CGRect(
            x: regionX * pixelW,
            y: (1 - maxY) * pixelH,
            width: regionWidth * pixelW,
            height: (maxY - minY) * pixelH
        ).integral.intersection(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        guard crop.width > 4, crop.height > 4, let texture = cg.cropping(to: crop) else { return false }
        let scale = max(rect.width / crop.width, rect.height / crop.height)
        let drawSize = CGSize(width: crop.width * scale, height: crop.height * scale)
        let drawRect = CGRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(texture, in: drawRect)
        context.restoreGState()
        return true
    }

    private func drawPortrait(_ image: NSImage, record: PetRecord, in rect: CGRect, context: CGContext) {
        guard let cg = image.cgImageValue else {
            context.setFillColor(NSColor(hex: "#E9C7A7")!.cgColor)
            context.fill(rect)
            return
        }
        let pixelW = CGFloat(cg.width), pixelH = CGFloat(cg.height)
        var crop = CGRect(
            x: CGFloat(record.faceX) * pixelW,
            y: (1 - CGFloat(record.faceY + record.faceH)) * pixelH,
            width: CGFloat(record.faceW) * pixelW,
            height: CGFloat(record.faceH) * pixelH
        ).integral
        crop = crop.intersection(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        guard crop.width > 2, crop.height > 2, let cropped = cg.cropping(to: crop) else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(cropped, in: rect)
        context.restoreGState()
    }

    private func drawExpression(state: PetMotion, action: PetActionMode, phase: CGFloat, headRect: CGRect, record: PetRecord, tracking: Bool, context: CGContext) {
        let ink = NSColor(hex: "#2C2927")!
        let points = facialPoints(record: record, in: headRect, tracking: tracking)
        let eyeGap = max(4, abs(points.rightEye.x - points.leftEye.x))
        let eyeRadius = clamp(eyeGap * 0.18, 2.5, 6)
        func closedEye(_ center: CGPoint) {
            context.beginPath()
            context.move(to: CGPoint(x: center.x - eyeRadius * 1.25, y: center.y))
            context.addQuadCurve(to: CGPoint(x: center.x + eyeRadius * 1.25, y: center.y), control: CGPoint(x: center.x, y: center.y - eyeRadius))
            context.setStrokeColor(ink.cgColor); context.setLineWidth(2); context.setLineCap(.round); context.strokePath()
        }
        func wideEye(_ center: CGPoint) {
            let rect = CGRect(x: center.x - eyeRadius, y: center.y - eyeRadius * 1.15, width: eyeRadius * 2, height: eyeRadius * 2.3)
            context.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor); context.fillEllipse(in: rect)
            context.setStrokeColor(ink.cgColor); context.setLineWidth(1.4); context.strokeEllipse(in: rect)
            context.setFillColor(ink.cgColor); context.fillEllipse(in: rect.insetBy(dx: eyeRadius * 0.57, dy: eyeRadius * 0.57))
        }

        switch state {
        case .dragging:
            drawLine(context, from: CGPoint(x: points.leftEye.x - eyeRadius, y: points.leftEye.y + eyeRadius * 1.8), to: CGPoint(x: points.leftEye.x + eyeRadius, y: points.leftEye.y + eyeRadius * 1.25), width: 2.1, color: ink)
            drawLine(context, from: CGPoint(x: points.rightEye.x - eyeRadius, y: points.rightEye.y + eyeRadius * 1.25), to: CGPoint(x: points.rightEye.x + eyeRadius, y: points.rightEye.y + eyeRadius * 1.8), width: 2.1, color: ink)
            let dropCenter = CGPoint(x: headRect.maxX - 4, y: headRect.maxY - 8)
            context.setFillColor(NSColor(hex: "#75C9E8")!.cgColor)
            context.fillEllipse(in: CGRect(x: dropCenter.x - 3, y: dropCenter.y - 5, width: 6, height: 10))

        case .falling:
            wideEye(points.leftEye); wideEye(points.rightEye)
            context.setStrokeColor(ink.cgColor); context.setLineWidth(2)
            context.strokeEllipse(in: CGRect(x: points.mouth.x - 4, y: points.mouth.y - 5, width: 8, height: 10))

        case .landed:
            for center in [points.leftEye, points.rightEye] {
                drawLine(context, from: CGPoint(x: center.x - 3, y: center.y - 3), to: CGPoint(x: center.x + 3, y: center.y + 3), width: 1.8, color: ink)
                drawLine(context, from: CGPoint(x: center.x - 3, y: center.y + 3), to: CGPoint(x: center.x + 3, y: center.y - 3), width: 1.8, color: ink)
            }
            for i in 0..<3 {
                let a = phase + CGFloat(i) * 2.09
                let p = CGPoint(x: headRect.midX + cos(a) * headRect.width * 0.32, y: headRect.maxY + sin(a) * 3)
                context.setFillColor(NSColor(hex: i == 0 ? "#F29D8D" : "#FFCF5A")!.cgColor)
                context.fillEllipse(in: CGRect(x: p.x-2.2, y: p.y-2.2, width: 4.4, height: 4.4))
            }

        case .reacting:
            closedEye(points.leftEye); closedEye(points.rightEye)
            context.setFillColor(NSColor(hex: "#F48E91")!.withAlphaComponent(0.58).cgColor)
            context.fillEllipse(in: CGRect(x: points.leftEye.x - eyeRadius * 1.8, y: points.mouth.y, width: eyeRadius * 1.7, height: eyeRadius * 0.8))
            context.fillEllipse(in: CGRect(x: points.rightEye.x + eyeRadius * 0.1, y: points.mouth.y, width: eyeRadius * 1.7, height: eyeRadius * 0.8))
            drawHeart(at: CGPoint(x: headRect.maxX + 3, y: headRect.maxY - 2 + sin(phase) * 2), context: context)

        case .climbing:
            drawMotionMark(x: headRect.minX - 5, y: headRect.midY, flip: false, context: context)
            drawMotionMark(x: headRect.maxX + 5, y: headRect.midY, flip: true, context: context)

        case .walking:
            if action == .dance {
                closedEye(points.leftEye); closedEye(points.rightEye)
                context.beginPath(); context.move(to: CGPoint(x: points.mouth.x - 4, y: points.mouth.y))
                context.addQuadCurve(to: CGPoint(x: points.mouth.x + 4, y: points.mouth.y), control: CGPoint(x: points.mouth.x, y: points.mouth.y - 4))
                context.setStrokeColor(ink.cgColor); context.setLineWidth(1.8); context.strokePath()
            } else if action == .hop {
                wideEye(points.leftEye); wideEye(points.rightEye)
            }
        }
    }

    private func drawLine(_ context: CGContext, from: CGPoint, to: CGPoint, width: CGFloat, color: NSColor) {
        context.beginPath()
        context.move(to: from)
        context.addLine(to: to)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.strokePath()
    }

    private func drawShoe(at point: CGPoint, direction: CGFloat, ink: NSColor, context: CGContext) {
        context.setFillColor(ink.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - 7 + direction*2, y: point.y - 4, width: 14, height: 8))
        context.setFillColor(NSColor(hex: "#F7F1E6")!.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - 4 + direction*3, y: point.y - 1, width: 7, height: 3))
    }

    private func drawHand(at point: CGPoint, ink: NSColor, context: CGContext) {
        context.setFillColor(ink.cgColor)
        context.fillEllipse(in: CGRect(x: point.x-5, y: point.y-5, width: 10, height: 10))
        context.setFillColor(NSColor(hex: "#F6D0B3")!.cgColor)
        context.fillEllipse(in: CGRect(x: point.x-3.2, y: point.y-3.2, width: 6.4, height: 6.4))
    }

    private func drawMotionMark(x: CGFloat, y: CGFloat, flip: Bool, context: CGContext) {
        let sign: CGFloat = flip ? -1 : 1
        context.beginPath()
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + sign*7, y: y+4))
        context.addLine(to: CGPoint(x: x + sign*3, y: y+10))
        context.setStrokeColor(NSColor(hex: "#F29D8D")!.cgColor)
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private func drawHeart(at point: CGPoint, context: CGContext) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: point.x, y: point.y-5))
        p.addCurve(to: CGPoint(x: point.x-8, y: point.y+2), control1: CGPoint(x: point.x-4, y: point.y-1), control2: CGPoint(x: point.x-9, y: point.y-1))
        p.addCurve(to: CGPoint(x: point.x, y: point.y+9), control1: CGPoint(x: point.x-8, y: point.y+7), control2: CGPoint(x: point.x-3, y: point.y+9))
        p.addCurve(to: CGPoint(x: point.x+8, y: point.y+2), control1: CGPoint(x: point.x+3, y: point.y+9), control2: CGPoint(x: point.x+8, y: point.y+7))
        p.addCurve(to: CGPoint(x: point.x, y: point.y-5), control1: CGPoint(x: point.x+9, y: point.y-1), control2: CGPoint(x: point.x+4, y: point.y-1))
        context.addPath(p)
        context.setFillColor(NSColor(hex: "#F26C74")!.cgColor)
        context.fillPath()
    }
}

// MARK: - Manager UI

protocol DropZoneDelegate: AnyObject {
    func dropZoneDidChooseFiles(_ urls: [URL])
}

final class HejButton: NSButton {
    var fillColor = NSColor(hex: "#DDEBE6")! { didSet { needsDisplay = true } }
    var titleColor = NSColor(hex: "#355F57")! { didSet { needsDisplay = true } }
    var outlineColor: NSColor? { didSet { needsDisplay = true } }

    convenience init(title: String, target: AnyObject?, action: Selector?, fill: NSColor, titleColor: NSColor, outline: NSColor? = nil) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.fillColor = fill
        self.titleColor = titleColor
        self.outlineColor = outline
        self.font = .systemFont(ofSize: 12.5, weight: .semibold)
        self.isBordered = false
        self.focusRingType = .none
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        (isHighlighted ? fillColor.mixed(with: .black, amount: 0.09) : fillColor).setFill()
        path.fill()
        if let outlineColor {
            outlineColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: titleColor,
            .paragraphStyle: paragraph
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let titleRect = NSRect(x: 5, y: (bounds.height - size.height) / 2 - 0.5, width: bounds.width - 10, height: size.height + 2)
        (title as NSString).draw(in: titleRect, withAttributes: attributes)
    }
}

final class DropZoneView: NSView {
    weak var delegate: DropZoneDelegate?
    var isHovering = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isHovering = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isHovering = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHovering = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let filtered = urls.filter { ["jpg", "jpeg", "png", "heic", "webp", "tiff"].contains($0.pathExtension.lowercased()) }
        guard !filtered.isEmpty else { return false }
        delegate?.dropZoneDidChooseFiles(filtered)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        (isHovering ? NSColor(hex: "#E4F0EC")! : NSColor.white.withAlphaComponent(0.72)).setFill()
        path.fill()
        let border = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        border.setLineDash([6, 5], count: 2, phase: 0)
        border.lineWidth = isHovering ? 2.2 : 1.4
        (isHovering ? NSColor(hex: "#5F958A")! : NSColor(hex: "#BBB4A8")!).setStroke()
        border.stroke()
    }
}

final class PetCardView: NSView {
    let record: PetRecord
    let preview: NSImage
    var onDelete: ((UUID) -> Void)?
    var onToggle: ((UUID, Bool) -> Void)?
    var onCrop: ((UUID) -> Void)?
    var onClothing: ((UUID) -> Void)?
    private let toggle = NSSwitch()

    init(record: PetRecord, preview: NSImage) {
        self.record = record
        self.preview = preview
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 76))
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.82).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(hex: "#E8E2D7")!.cgColor

        let name = NSTextField(labelWithString: record.name)
        name.font = .systemFont(ofSize: 14.5, weight: .semibold)
        name.textColor = NSColor(hex: "#2C2927")
        name.frame = NSRect(x: 78, y: 28, width: 126, height: 20)
        addSubview(name)

        let cropButton = HejButton(
            title: "调整裁切",
            target: self,
            action: #selector(cropPressed),
            fill: NSColor(hex: "#EEF3EF")!,
            titleColor: NSColor(hex: "#456C64")!,
            outline: NSColor(hex: "#D3E1DC")!
        )
        cropButton.frame = NSRect(x: 212, y: 22, width: 82, height: 31)
        cropButton.toolTip = "可选自动识别、旧版矩形范围或自由圈选"
        addSubview(cropButton)

        let clothingButton = HejButton(
            title: "衣服材质",
            target: self,
            action: #selector(clothingPressed),
            fill: NSColor(hex: "#F3EDE5")!,
            titleColor: NSColor(hex: "#745E48")!,
            outline: NSColor(hex: "#E2D4C4")!
        )
        clothingButton.frame = NSRect(x: 300, y: 22, width: 88, height: 31)
        clothingButton.toolTip = "自动检测衣服，或用画笔涂抹一小块衣料"
        addSubview(clothingButton)

        toggle.state = record.isVisible ? .on : .off
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        toggle.frame = NSRect(x: 408, y: 26, width: 38, height: 24)
        toggle.toolTip = "在桌面显示"
        addSubview(toggle)

        let deleteButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")!, target: self, action: #selector(deletePressed))
        deleteButton.isBordered = false
        deleteButton.contentTintColor = NSColor(hex: "#A55B58")
        deleteButton.frame = NSRect(x: 456, y: 25, width: 30, height: 30)
        deleteButton.toolTip = "删除宠物"
        addSubview(deleteButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { false }

    @objc private func deletePressed() { onDelete?(record.id) }
    @objc private func toggleChanged() { onToggle?(record.id, toggle.state == .on) }
    @objc private func cropPressed() { onCrop?(record.id) }
    @objc private func clothingPressed() { onClothing?(record.id) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let imageRect = NSRect(x: 14, y: 10, width: 56, height: 56)
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: imageRect, xRadius: 16, yRadius: 16)
        clip.addClip()
        preview.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(roundedRect: imageRect, xRadius: 16, yRadius: 16)
        ring.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.stroke()

    }
}

final class CropEditorView: NSView {
    enum DragMode { case none, move, new, topLeft, topRight, bottomLeft, bottomRight }

    let image: NSImage
    var selectionNormalized: CGRect
    private var dragMode: DragMode = .none
    private var dragStart = CGPoint.zero
    private var originalRect = CGRect.zero

    init(frame: CGRect, image: NSImage, selection: CGRect) {
        self.image = image
        self.selectionNormalized = selection
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private var imageRect: CGRect {
        let area = bounds.insetBy(dx: 16, dy: 16)
        guard image.size.width > 0, image.size.height > 0 else { return area }
        let scale = min(area.width / image.size.width, area.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    private var selectionRect: CGRect {
        let box = imageRect
        return CGRect(
            x: box.minX + selectionNormalized.minX * box.width,
            y: box.minY + (1 - selectionNormalized.maxY) * box.height,
            width: selectionNormalized.width * box.width,
            height: selectionNormalized.height * box.height
        )
    }

    private func handlePoints(for rect: CGRect) -> [(DragMode, CGPoint)] {
        [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = selectionRect
        dragStart = point
        originalRect = rect
        if let hit = handlePoints(for: rect).first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= 13 }) {
            dragMode = hit.0
        } else if rect.contains(point) {
            dragMode = .move
        } else if imageRect.contains(point) {
            dragMode = .new
            originalRect = CGRect(origin: point, size: .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragMode != .none else { return }
        let box = imageRect
        var point = convert(event.locationInWindow, from: nil)
        point.x = clamp(point.x, box.minX, box.maxX)
        point.y = clamp(point.y, box.minY, box.maxY)
        let minimum: CGFloat = 42
        var rect = originalRect

        switch dragMode {
        case .move:
            let dx = point.x - dragStart.x
            let dy = point.y - dragStart.y
            rect.origin.x = clamp(originalRect.minX + dx, box.minX, box.maxX - originalRect.width)
            rect.origin.y = clamp(originalRect.minY + dy, box.minY, box.maxY - originalRect.height)
        case .new:
            rect = CGRect(
                x: min(dragStart.x, point.x), y: min(dragStart.y, point.y),
                width: max(minimum, abs(point.x - dragStart.x)),
                height: max(minimum, abs(point.y - dragStart.y))
            ).intersection(box)
        case .topLeft:
            rect = CGRect(x: min(point.x, originalRect.maxX - minimum), y: min(point.y, originalRect.maxY - minimum), width: originalRect.maxX - min(point.x, originalRect.maxX - minimum), height: originalRect.maxY - min(point.y, originalRect.maxY - minimum))
        case .topRight:
            let right = max(point.x, originalRect.minX + minimum)
            let top = min(point.y, originalRect.maxY - minimum)
            rect = CGRect(x: originalRect.minX, y: top, width: right - originalRect.minX, height: originalRect.maxY - top)
        case .bottomLeft:
            let left = min(point.x, originalRect.maxX - minimum)
            let bottom = max(point.y, originalRect.minY + minimum)
            rect = CGRect(x: left, y: originalRect.minY, width: originalRect.maxX - left, height: bottom - originalRect.minY)
        case .bottomRight:
            rect = CGRect(x: originalRect.minX, y: originalRect.minY, width: max(minimum, point.x - originalRect.minX), height: max(minimum, point.y - originalRect.minY))
        case .none:
            return
        }
        rect = rect.intersection(box)
        selectionNormalized = CGRect(
            x: clamp((rect.minX - box.minX) / box.width, 0, 1),
            y: clamp(1 - (rect.maxY - box.minY) / box.height, 0, 1),
            width: clamp(rect.width / box.width, 0.04, 1),
            height: clamp(rect.height / box.height, 0.04, 1)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { dragMode = .none }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: "#242322")!.setFill()
        bounds.fill()
        let box = imageRect
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

        let crop = selectionRect
        NSColor.black.withAlphaComponent(0.56).setFill()
        NSRect(x: box.minX, y: box.minY, width: box.width, height: max(0, crop.minY - box.minY)).fill()
        NSRect(x: box.minX, y: crop.maxY, width: box.width, height: max(0, box.maxY - crop.maxY)).fill()
        NSRect(x: box.minX, y: crop.minY, width: max(0, crop.minX - box.minX), height: crop.height).fill()
        NSRect(x: crop.maxX, y: crop.minY, width: max(0, box.maxX - crop.maxX), height: crop.height).fill()

        let border = NSBezierPath(rect: crop)
        border.lineWidth = 2.2
        NSColor(hex: "#D9F3EA")!.setStroke()
        border.stroke()
        for (_, point) in handlePoints(for: crop) {
            NSColor(hex: "#4D887C")!.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

final class MaskPaintView: NSView {
    private enum Mode { case outline, paint, erase }
    let image: NSImage
    private(set) var strokes: [PaintStroke] = []
    private var currentStroke: Int?
    private var mode: Mode = .outline
    private(set) var brushDiameter: CGFloat = 24

    init(frame: CGRect, image: NSImage, strokes: [PaintStroke] = []) {
        self.image = image
        self.strokes = strokes
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    private var imageRect: CGRect {
        let area = bounds.insetBy(dx: 16, dy: 16)
        guard image.size.width > 0, image.size.height > 0 else { return area }
        let scale = min(area.width / image.size.width, area.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    var hasPaint: Bool { strokes.contains { !$0.erasing && !$0.points.isEmpty } }

    func setMode(_ segment: Int) {
        mode = segment == 1 ? .paint : (segment == 2 ? .erase : .outline)
    }
    func setBrushDiameter(_ value: CGFloat) { brushDiameter = clamp(value, 8, 90) }
    func undo() { if !strokes.isEmpty { strokes.removeLast(); needsDisplay = true } }
    func clearMask() { strokes.removeAll(); currentStroke = nil; needsDisplay = true }

    private func normalized(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: clamp((point.x - rect.minX) / rect.width, 0, 1), y: clamp((point.y - rect.minY) / rect.height, 0, 1))
    }

    private func displayPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * imageRect.width, y: imageRect.minY + point.y * imageRect.height)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        let radius = brushDiameter / (2 * max(1, min(imageRect.width, imageRect.height)))
        strokes.append(PaintStroke(
            points: [normalized(point)], radius: radius,
            erasing: mode == .erase,
            fillsInterior: mode == .outline
        ))
        currentStroke = strokes.count - 1
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = currentStroke else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x = clamp(point.x, imageRect.minX, imageRect.maxX)
        point.y = clamp(point.y, imageRect.minY, imageRect.maxY)
        let value = normalized(point)
        if let last = strokes[index].points.last,
           hypot((value.x - last.x) * imageRect.width, (value.y - last.y) * imageRect.height) < max(2, brushDiameter / 5) { return }
        strokes[index].points.append(value)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { currentStroke = nil; needsDisplay = true }

    private func drawStroke(_ stroke: PaintStroke) {
        guard let first = stroke.points.first else { return }
        let width = stroke.radius * 2 * min(imageRect.width, imageRect.height)
        let color = stroke.erasing ? NSColor.black.withAlphaComponent(0.60) : NSColor(hex: "#83E2C8")!.withAlphaComponent(0.62)
        color.setFill(); color.setStroke()
        if stroke.points.count == 1 {
            let point = displayPoint(first)
            NSBezierPath(ovalIn: CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width)).fill()
            return
        }
        let path = NSBezierPath(); path.move(to: displayPoint(first))
        for point in stroke.points.dropFirst() { path.line(to: displayPoint(point)) }
        if stroke.fillsInterior == true { path.close() }
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: "#242322")!.setFill(); bounds.fill()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSColor.black.withAlphaComponent(0.42).setFill(); imageRect.fill()
        for stroke in strokes { drawStroke(stroke) }
        if !hasPaint {
            let prompt = "沿人物轮廓画一圈 · 松手后圈内全部保留，交叉也不会反选" as NSString
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            prompt.draw(in: CGRect(x: 55, y: bounds.midY - 18, width: bounds.width - 110, height: 36), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        }
    }
}

enum HeadCropChoice {
    case automatic
    case rectangle(CGRect)
    case freehand([PaintStroke])
}

final class CropEditorController: NSWindowController {
    private weak var parentWindow: NSWindow?
    private let cropView: MaskPaintView
    private let rectangleView: CropEditorView
    private let methodControl = NSSegmentedControl(labels: ["自动识别", "矩形范围", "自由圈选"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: ["圈选轮廓", "涂抹补选", "橡皮擦"], trackingMode: .selectOne, target: nil, action: nil)
    private let brushSlider = NSSlider(value: 24, minValue: 8, maxValue: 90, target: nil, action: nil)
    private var hint: NSTextField!
    private var applyButton: HejButton!
    private var freehandControls: [NSControl] = []
    var onApply: ((HeadCropChoice) -> Void)?

    init(record: PetRecord, image: NSImage) {
        let editorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        editorWindow.title = "调整头部裁切"
        editorWindow.backgroundColor = NSColor(hex: "#F7F3EA")
        let selection = CGRect(x: record.faceX, y: record.faceY, width: record.faceW, height: record.faceH)
        let editorFrame = NSRect(x: 20, y: 100, width: 720, height: 555)
        cropView = MaskPaintView(frame: editorFrame, image: image, strokes: record.headMaskStrokes ?? [])
        rectangleView = CropEditorView(frame: editorFrame, image: image, selection: selection)
        super.init(window: editorWindow)
        guard let content = editorWindow.contentView else { return }
        content.addSubview(rectangleView)
        content.addSubview(cropView)

        methodControl.selectedSegment = 1
        methodControl.target = self
        methodControl.action = #selector(methodChanged)
        methodControl.frame = NSRect(x: 210, y: 674, width: 340, height: 30)
        methodControl.toolTip = "选择自动识别、旧版矩形框，或画线自由圈选"
        content.addSubview(methodControl)

        hint = NSTextField(labelWithString: "拖动矩形或四角圆点，框住头发、脸和需要保留的脖子。")
        hint.font = .systemFont(ofSize: 12.5)
        hint.textColor = NSColor(hex: "#6F6A62")
        hint.frame = NSRect(x: 24, y: 72, width: 500, height: 20)
        content.addSubview(hint)

        modeControl.selectedSegment = 0
        modeControl.target = self; modeControl.action = #selector(modeChanged)
        modeControl.frame = NSRect(x: 24, y: 34, width: 220, height: 28)
        content.addSubview(modeControl)
        brushSlider.target = self; brushSlider.action = #selector(brushChanged)
        brushSlider.frame = NSRect(x: 252, y: 34, width: 90, height: 28)
        content.addSubview(brushSlider)
        let undo = HejButton(title: "撤销", target: self, action: #selector(undoPressed), fill: NSColor(hex: "#EEF1F0")!, titleColor: NSColor(hex: "#53645F")!, outline: NSColor(hex: "#D4DDDA")!)
        undo.frame = NSRect(x: 350, y: 32, width: 58, height: 31)
        content.addSubview(undo)
        let reset = HejButton(title: "清空", target: self, action: #selector(resetPressed), fill: NSColor(hex: "#EEF1F0")!, titleColor: NSColor(hex: "#53645F")!, outline: NSColor(hex: "#D4DDDA")!)
        reset.frame = NSRect(x: 416, y: 32, width: 58, height: 31)
        content.addSubview(reset)
        freehandControls = [modeControl, brushSlider, undo, reset]

        let cancel = HejButton(title: "取消", target: self, action: #selector(cancelPressed), fill: .white, titleColor: NSColor(hex: "#655F57")!, outline: NSColor(hex: "#D8D3C9")!)
        cancel.frame = NSRect(x: 560, y: 28, width: 80, height: 36)
        content.addSubview(cancel)
        applyButton = HejButton(title: "使用矩形范围", target: self, action: #selector(applyPressed), fill: NSColor(hex: "#DDEBE6")!, titleColor: NSColor(hex: "#355F57")!, outline: NSColor(hex: "#BFD8D0")!)
        applyButton.frame = NSRect(x: 648, y: 28, width: 96, height: 36)
        content.addSubview(applyButton)
        methodChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(over parent: NSWindow) {
        parentWindow = parent
        guard let window else { return }
        parent.beginSheet(window)
    }

    @objc private func modeChanged() { cropView.setMode(modeControl.selectedSegment) }
    @objc private func brushChanged() { cropView.setBrushDiameter(CGFloat(brushSlider.doubleValue)) }
    @objc private func undoPressed() { cropView.undo() }
    @objc private func resetPressed() { cropView.clearMask() }

    @objc private func methodChanged() {
        let method = methodControl.selectedSegment
        let isFreehand = method == 2
        cropView.isHidden = !isFreehand
        rectangleView.isHidden = isFreehand
        freehandControls.forEach { $0.isEnabled = isFreehand }
        switch method {
        case 0:
            hint.stringValue = "自动检测头发、脸和脖子；不满意可切换到矩形范围或自由圈选。"
            applyButton.title = "使用自动识别"
        case 2:
            hint.stringValue = "沿轮廓画一整圈，松手后圈内全部保留；线条交叉也不会把中间挖空。"
            applyButton.title = "使用自由圈选"
        default:
            hint.stringValue = "拖动矩形或四角圆点，框住头发、脸和需要保留的脖子。"
            applyButton.title = "使用矩形范围"
        }
    }

    @objc private func cancelPressed() {
        guard let parentWindow, let window else { return }
        parentWindow.endSheet(window)
    }

    @objc private func applyPressed() {
        switch methodControl.selectedSegment {
        case 0:
            onApply?(.automatic)
        case 2:
            guard cropView.hasPaint else { NSSound.beep(); return }
            onApply?(.freehand(cropView.strokes))
        default:
            onApply?(.rectangle(rectangleView.selectionNormalized))
        }
        guard let parentWindow, let window else { return }
        parentWindow.endSheet(window)
    }
}

final class ClothingEditorController: NSWindowController {
    private weak var parentWindow: NSWindow?
    private let cropView: MaskPaintView
    private let modeControl = NSSegmentedControl(labels: ["圈选衣料", "涂抹补选", "橡皮擦"], trackingMode: .selectOne, target: nil, action: nil)
    private let brushSlider = NSSlider(value: 24, minValue: 8, maxValue: 90, target: nil, action: nil)
    var onApply: (([PaintStroke]?) -> Void)?

    init(record: PetRecord, image: NSImage) {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 690),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.title = "衣服材质"
        panel.backgroundColor = NSColor(hex: "#F7F3EA")
        cropView = MaskPaintView(frame: NSRect(x: 20, y: 100, width: 720, height: 570), image: image, strokes: record.clothingMaskStrokes ?? [])
        super.init(window: panel)
        guard let content = panel.contentView else { return }
        content.addSubview(cropView)

        let hint = NSTextField(labelWithString: "沿一块干净衣料画一圈，内部会自动填满；也可涂抹补选或擦除。")
        hint.font = .systemFont(ofSize: 12.5)
        hint.textColor = NSColor(hex: "#6F6A62")
        hint.frame = NSRect(x: 24, y: 72, width: 430, height: 20)
        content.addSubview(hint)

        modeControl.selectedSegment = 0; modeControl.target = self; modeControl.action = #selector(modeChanged)
        modeControl.frame = NSRect(x: 24, y: 34, width: 220, height: 28); content.addSubview(modeControl)
        brushSlider.target = self; brushSlider.action = #selector(brushChanged)
        brushSlider.frame = NSRect(x: 252, y: 34, width: 90, height: 28); content.addSubview(brushSlider)
        let undo = HejButton(title: "撤销", target: self, action: #selector(undoPressed), fill: NSColor(hex: "#EEF1F0")!, titleColor: NSColor(hex: "#53645F")!, outline: NSColor(hex: "#D4DDDA")!)
        undo.frame = NSRect(x: 350, y: 32, width: 58, height: 31); content.addSubview(undo)
        let auto = HejButton(title: "自动检测", target: self, action: #selector(autoPressed), fill: NSColor(hex: "#EEF3EF")!, titleColor: NSColor(hex: "#456C64")!, outline: NSColor(hex: "#D3E1DC")!)
        auto.frame = NSRect(x: 416, y: 32, width: 82, height: 31)
        content.addSubview(auto)
        let cancel = HejButton(title: "取消", target: self, action: #selector(cancelPressed), fill: .white, titleColor: NSColor(hex: "#655F57")!, outline: NSColor(hex: "#D8D3C9")!)
        cancel.frame = NSRect(x: 560, y: 28, width: 80, height: 36)
        content.addSubview(cancel)
        let apply = HejButton(title: "使用涂抹衣料", target: self, action: #selector(applyPressed), fill: NSColor(hex: "#E9DDD0")!, titleColor: NSColor(hex: "#684F3C")!, outline: NSColor(hex: "#D8C3AE")!)
        apply.frame = NSRect(x: 648, y: 28, width: 96, height: 36)
        content.addSubview(apply)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(over parent: NSWindow) {
        parentWindow = parent
        guard let window else { return }
        parent.beginSheet(window)
    }

    @objc private func modeChanged() { cropView.setMode(modeControl.selectedSegment) }
    @objc private func brushChanged() { cropView.setBrushDiameter(CGFloat(brushSlider.doubleValue)) }
    @objc private func undoPressed() { cropView.undo() }
    @objc private func autoPressed() { finish(with: nil) }
    @objc private func applyPressed() {
        guard cropView.hasPaint else { NSSound.beep(); return }
        finish(with: cropView.strokes)
    }
    @objc private func cancelPressed() {
        guard let parentWindow, let window else { return }
        parentWindow.endSheet(window)
    }
    private func finish(with strokes: [PaintStroke]?) {
        onApply?(strokes)
        guard let parentWindow, let window else { return }
        parentWindow.endSheet(window)
    }
}

final class InteractionSettingsController: NSWindowController {
    private weak var parentWindow: NSWindow?
    private let settings: BubbleSettings
    private let modePopup = NSPopUpButton()
    private let fixedField = NSTextField()
    private let randomMinField = NSTextField()
    private let randomMaxField = NSTextField()
    private let fpsPopup = NSPopUpButton()
    private let actionPopup = NSPopUpButton()
    private let faceTrackingCheck = NSButton(checkboxWithTitle: "自动检测五官，把表情贴到真实眼睛和嘴巴位置", target: nil, action: nil)
    private let messageView = NSTextView()
    private let dragMessageView = NSTextView()
    var onSave: (() -> Void)?

    init(settings: BubbleSettings) {
        self.settings = settings
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "互动设置"
        panel.backgroundColor = NSColor(hex: "#F7F3EA")
        super.init(window: panel)
        guard let content = panel.contentView else { return }

        addLabel("动作模式", frame: NSRect(x: 28, y: 638, width: 100, height: 22), to: content, bold: true)
        actionPopup.addItems(withTitles: PetActionMode.allCases.map(\.title))
        actionPopup.selectItem(at: PetActionMode.allCases.firstIndex(of: settings.actionMode) ?? 0)
        actionPopup.frame = NSRect(x: 128, y: 632, width: 180, height: 30)
        content.addSubview(actionPopup)
        faceTrackingCheck.state = settings.faceTrackingEnabled ? .on : .off
        faceTrackingCheck.frame = NSRect(x: 28, y: 598, width: 390, height: 24)
        faceTrackingCheck.font = .systemFont(ofSize: 12.5, weight: .medium)
        content.addSubview(faceTrackingCheck)

        addLabel("气泡出现时间", frame: NSRect(x: 28, y: 566, width: 150, height: 22), to: content, bold: true)
        modePopup.addItems(withTitles: ["固定间隔", "随机时间"])
        modePopup.selectItem(at: settings.mode == .fixed ? 0 : 1)
        modePopup.frame = NSRect(x: 28, y: 525, width: 120, height: 30)
        content.addSubview(modePopup)

        addLabel("固定（分钟）", frame: NSRect(x: 168, y: 543, width: 95, height: 18), to: content)
        fixedField.stringValue = format(settings.fixedMinutes)
        fixedField.frame = NSRect(x: 168, y: 515, width: 92, height: 28)
        content.addSubview(fixedField)
        addLabel("随机最短", frame: NSRect(x: 282, y: 543, width: 80, height: 18), to: content)
        randomMinField.stringValue = format(settings.randomMinMinutes)
        randomMinField.frame = NSRect(x: 282, y: 515, width: 86, height: 28)
        content.addSubview(randomMinField)
        addLabel("随机最长", frame: NSRect(x: 386, y: 543, width: 80, height: 18), to: content)
        randomMaxField.stringValue = format(settings.randomMaxMinutes)
        randomMaxField.frame = NSRect(x: 386, y: 515, width: 86, height: 28)
        content.addSubview(randomMaxField)

        addLabel("动画帧数", frame: NSRect(x: 28, y: 472, width: 100, height: 22), to: content, bold: true)
        fpsPopup.addItems(withTitles: ["15 FPS", "24 FPS", "30 FPS", "45 FPS", "60 FPS"])
        let supported = [15, 24, 30, 45, 60]
        fpsPopup.selectItem(at: supported.firstIndex(of: settings.animationFPS) ?? 2)
        fpsPopup.frame = NSRect(x: 128, y: 466, width: 110, height: 30)
        content.addSubview(fpsPopup)
        addLabel("30 FPS 较轻量；60 FPS 更顺滑但更耗电。", frame: NSRect(x: 250, y: 471, width: 280, height: 20), to: content)

        addLabel("平时说的话（每行一句）", frame: NSRect(x: 28, y: 426, width: 220, height: 22), to: content, bold: true)
        messageView.string = settings.messages.joined(separator: "\n")
        content.addSubview(makeEditor(messageView, frame: NSRect(x: 28, y: 250, width: 504, height: 170)))

        addLabel("被拽起来时说的话（每行一句）", frame: NSRect(x: 28, y: 210, width: 260, height: 22), to: content, bold: true)
        dragMessageView.string = settings.dragMessages.joined(separator: "\n")
        content.addSubview(makeEditor(dragMessageView, frame: NSRect(x: 28, y: 82, width: 504, height: 122)))

        let cancel = HejButton(title: "取消", target: self, action: #selector(cancelPressed), fill: .white, titleColor: NSColor(hex: "#655F57")!, outline: NSColor(hex: "#D8D3C9")!)
        cancel.frame = NSRect(x: 350, y: 27, width: 80, height: 36)
        content.addSubview(cancel)
        let save = HejButton(title: "保存设置", target: self, action: #selector(savePressed), fill: NSColor(hex: "#DDEBE6")!, titleColor: NSColor(hex: "#355F57")!, outline: NSColor(hex: "#BFD8D0")!)
        save.frame = NSRect(x: 442, y: 27, width: 90, height: 36)
        content.addSubview(save)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(format: "%.1f", number)
    }

    private func addLabel(_ text: String, frame: CGRect, to view: NSView, bold: Bool = false) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: bold ? 13.5 : 11.5, weight: bold ? .semibold : .regular)
        label.textColor = NSColor(hex: bold ? "#393632" : "#746E65")
        label.frame = frame
        view.addSubview(label)
    }

    private func makeEditor(_ textView: NSTextView, frame: CGRect) -> NSScrollView {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.white.withAlphaComponent(0.86)
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = NSColor(hex: "#393632")
        textView.backgroundColor = NSColor.white.withAlphaComponent(0.86)
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }

    private func lines(from text: String, fallback: [String]) -> [String] {
        let values = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? fallback : values
    }

    func present(over parent: NSWindow) {
        parentWindow = parent
        guard let window else { return }
        parent.beginSheet(window)
    }

    @objc private func cancelPressed() {
        guard let parentWindow, let window else { return }
        parentWindow.endSheet(window)
    }

    @objc private func savePressed() {
        settings.mode = modePopup.indexOfSelectedItem == 0 ? .fixed : .random
        settings.fixedMinutes = clamp(Double(fixedField.stringValue) ?? 2, 0.1, 120)
        settings.randomMinMinutes = clamp(Double(randomMinField.stringValue) ?? 1, 0.1, 120)
        settings.randomMaxMinutes = clamp(Double(randomMaxField.stringValue) ?? 4, settings.randomMinMinutes, 240)
        let fpsValues = [15, 24, 30, 45, 60]
        settings.animationFPS = fpsValues[clamp(fpsPopup.indexOfSelectedItem, 0, fpsValues.count - 1)]
        settings.actionMode = PetActionMode.allCases[clamp(actionPopup.indexOfSelectedItem, 0, PetActionMode.allCases.count - 1)]
        settings.faceTrackingEnabled = faceTrackingCheck.state == .on
        settings.messages = lines(from: messageView.string, fallback: ["陪你一会儿呀"])
        settings.dragMessages = lines(from: dragMessageView.string, fallback: ["轻一点呀～"])
        settings.save()
        onSave?()
        guard let parentWindow, let window else { return }
        parentWindow.endSheet(window)
    }
}

final class ManagerBackgroundView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(colors: [NSColor(hex: "#F7F3EA")!, NSColor(hex: "#EEF3EF")!])!
        gradient.draw(in: bounds, angle: -35)
        NSColor.white.withAlphaComponent(0.30).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.maxX-190, y: -80, width: 250, height: 210)).fill()
        NSColor(hex: "#E6B8A3")!.withAlphaComponent(0.13).setFill()
        NSBezierPath(ovalIn: NSRect(x: -90, y: bounds.maxY-140, width: 230, height: 180)).fill()
    }
}

final class ManagerWindowController: NSWindowController, DropZoneDelegate, NSWindowDelegate {
    let store: PetStore
    let bubbleSettings: BubbleSettings
    weak var appDelegate: AppDelegate?
    private let root = ManagerBackgroundView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "还没有小宠物，先放一张喜欢的照片吧。")
    private let dropZone = DropZoneView()
    private let countLabel = NSTextField(labelWithString: "我的宠物")
    private var cropEditor: CropEditorController?
    private var clothingEditor: ClothingEditorController?
    private var interactionEditor: InteractionSettingsController?

    init(store: PetStore, bubbleSettings: BubbleSettings) {
        self.store = store
        self.bubbleSettings = bubbleSettings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 610),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hej’s Pets"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.setFrameAutosaveName("HejPetsManager")
        window.minSize = NSSize(width: 520, height: 560)
        window.backgroundColor = NSColor(hex: "#F7F3EA")
        super.init(window: window)
        window.delegate = self
        setupUI()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // This app must never become an invisible background process. Closing
        // the main window is therefore treated as an explicit app quit.
        NSApp.terminate(nil)
        return false
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        root.frame = content.bounds
        root.autoresizingMask = [.width, .height]
        content.addSubview(root)

        let title = NSTextField(labelWithString: "Hej’s Pets")
        title.font = .systemFont(ofSize: 31, weight: .bold)
        title.textColor = NSColor(hex: "#292725")
        title.frame = NSRect(x: 30, y: 38, width: 260, height: 38)
        root.addSubview(title)

        let subtitle = NSTextField(labelWithString: "把喜欢的人，放到 Dock 上陪你。")
        subtitle.font = .systemFont(ofSize: 13.5, weight: .regular)
        subtitle.textColor = NSColor(hex: "#6F6A62")
        subtitle.frame = NSRect(x: 31, y: 78, width: 310, height: 22)
        root.addSubview(subtitle)

        let maker = NSTextField(labelWithString: " HEJ 制作 ")
        maker.alignment = .center
        maker.font = .systemFont(ofSize: 11, weight: .bold)
        maker.textColor = NSColor(hex: "#426C64")
        maker.wantsLayer = true
        maker.layer?.backgroundColor = NSColor(hex: "#DDEBE6")!.cgColor
        maker.layer?.cornerRadius = 10
        maker.frame = NSRect(x: 449, y: 49, width: 80, height: 22)
        root.addSubview(maker)

        dropZone.frame = NSRect(x: 30, y: 118, width: 500, height: 105)
        dropZone.autoresizingMask = [.width]
        dropZone.delegate = self
        root.addSubview(dropZone)

        let symbol = NSImageView(image: NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)!)
        symbol.contentTintColor = NSColor(hex: "#5F958A")
        symbol.frame = NSRect(x: 35, y: 28, width: 44, height: 44)
        dropZone.addSubview(symbol)

        let addTitle = NSTextField(labelWithString: "放一张照片进来")
        addTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        addTitle.textColor = NSColor(hex: "#302E2B")
        addTitle.frame = NSRect(x: 93, y: 26, width: 210, height: 22)
        dropZone.addSubview(addTitle)

        let addHint = NSTextField(labelWithString: "拖到这里，或从相册选择 · JPG / PNG / HEIC")
        addHint.font = .systemFont(ofSize: 11.5)
        addHint.textColor = NSColor(hex: "#827B71")
        addHint.frame = NSRect(x: 93, y: 51, width: 310, height: 20)
        dropZone.addSubview(addHint)

        let addButton = HejButton(
            title: "选择照片",
            target: self,
            action: #selector(choosePhotos),
            fill: NSColor(hex: "#DDEBE6")!,
            titleColor: NSColor(hex: "#355F57")!,
            outline: NSColor(hex: "#C6DDD5")!
        )
        addButton.frame = NSRect(x: 393, y: 34, width: 88, height: 34)
        dropZone.addSubview(addButton)

        countLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = NSColor(hex: "#524E48")
        countLabel.frame = NSRect(x: 31, y: 243, width: 300, height: 22)
        root.addSubview(countLabel)

        let scroll = NSScrollView(frame: NSRect(x: 30, y: 270, width: 500, height: 260))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        root.addSubview(scroll)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        emptyLabel.font = .systemFont(ofSize: 12.5)
        emptyLabel.textColor = NSColor(hex: "#918A80")
        emptyLabel.alignment = .center

        let pauseButton = HejButton(
            title: "暂停爬行",
            target: self,
            action: #selector(togglePause),
            fill: NSColor.white.withAlphaComponent(0.72),
            titleColor: NSColor(hex: "#4F625D")!,
            outline: NSColor(hex: "#D8D3C9")!
        )
        pauseButton.frame = NSRect(x: 430, y: 558, width: 100, height: 30)
        pauseButton.autoresizingMask = [.minXMargin, .minYMargin]
        pauseButton.identifier = NSUserInterfaceItemIdentifier("pauseButton")
        root.addSubview(pauseButton)

        let interactionButton = HejButton(
            title: "互动设置",
            target: self,
            action: #selector(showInteractionSettings),
            fill: NSColor(hex: "#E8EEF4")!,
            titleColor: NSColor(hex: "#4E6475")!,
            outline: NSColor(hex: "#D2DDE5")!
        )
        interactionButton.frame = NSRect(x: 220, y: 558, width: 100, height: 30)
        interactionButton.autoresizingMask = [.minXMargin, .minYMargin]
        root.addSubview(interactionButton)

        let quitButton = HejButton(
            title: "退出应用",
            target: self,
            action: #selector(quitApplication),
            fill: NSColor(hex: "#F7E6E1")!,
            titleColor: NSColor(hex: "#8A4E49")!,
            outline: NSColor(hex: "#E8CCC4")!
        )
        quitButton.frame = NSRect(x: 330, y: 558, width: 90, height: 30)
        quitButton.autoresizingMask = [.minXMargin, .minYMargin]
        root.addSubview(quitButton)
    }

    func reload() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        countLabel.stringValue = store.pets.isEmpty ? "我的宠物" : "我的宠物  ·  \(store.pets.count) 只"
        if store.pets.isEmpty {
            emptyLabel.frame.size = NSSize(width: 500, height: 64)
            stack.addArrangedSubview(emptyLabel)
            emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            emptyLabel.heightAnchor.constraint(equalToConstant: 64).isActive = true
        } else {
            for record in store.pets {
                let image = NSImage(contentsOf: store.imageURL(for: record)) ?? NSImage(size: NSSize(width: 100, height: 100))
                let card = PetCardView(record: record, preview: image)
                card.onDelete = { [weak self] id in self?.askToDelete(id: id) }
                card.onToggle = { [weak self] id, visible in self?.appDelegate?.setPetVisible(id: id, visible: visible) }
                card.onCrop = { [weak self] id in self?.showCropEditor(id: id) }
                card.onClothing = { [weak self] id in self?.showClothingEditor(id: id) }
                stack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                card.heightAnchor.constraint(equalToConstant: 76).isActive = true
            }
        }
    }

    @objc func choosePhotos() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要变成桌宠的照片"
        panel.prompt = "变成桌宠"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.dropZoneDidChooseFiles(panel.urls) }
        }
    }

    func dropZoneDidChooseFiles(_ urls: [URL]) {
        for url in urls.prefix(8) {
            do {
                let record = try store.addPhoto(at: url)
                appDelegate?.addPetWindow(for: record)
            } catch {
                showError(error.localizedDescription)
            }
        }
        reload()
    }

    private func showCropEditor(id: UUID) {
        guard let record = store.pets.first(where: { $0.id == id }),
              let image = NSImage(contentsOf: store.imageURL(for: record)),
              let window else { return }
        let editor = CropEditorController(record: record, image: image)
        editor.onApply = { [weak self] choice in
            guard let self else { return }
            let updated: PetRecord?
            switch choice {
            case .automatic:
                updated = self.store.updateAutomaticHead(id: id)
            case .rectangle(let rect):
                updated = self.store.updateCrop(id: id, face: rect)
            case .freehand(let strokes):
                updated = self.store.updatePaintedHead(id: id, strokes: strokes)
            }
            guard updated != nil else { return }
            self.appDelegate?.refreshPetWindow(id: id)
            self.reload()
        }
        cropEditor = editor
        editor.present(over: window)
    }

    private func showClothingEditor(id: UUID) {
        guard let record = store.pets.first(where: { $0.id == id }),
              let image = NSImage(contentsOf: store.imageURL(for: record)),
              let window else { return }
        let editor = ClothingEditorController(record: record, image: image)
        editor.onApply = { [weak self] strokes in
            guard let self else { return }
            let updated = strokes.map { self.store.updatePaintedClothing(id: id, strokes: $0) } ?? self.store.updateClothingCrop(id: id, rect: nil)
            guard updated != nil else { return }
            self.appDelegate?.refreshPetWindow(id: id)
            self.reload()
        }
        clothingEditor = editor
        editor.present(over: window)
    }

    @objc private func showInteractionSettings() {
        guard let window else { return }
        let editor = InteractionSettingsController(settings: bubbleSettings)
        editor.onSave = { [weak self] in self?.appDelegate?.applyUpdatedSettings() }
        interactionEditor = editor
        editor.present(over: window)
    }

    private func askToDelete(id: UUID) {
        guard let record = store.pets.first(where: { $0.id == id }), let window else { return }
        let alert = NSAlert()
        alert.messageText = "删除“\(record.name)”？"
        alert.informativeText = "只会删除 Hej Pets 保存的副本，不会碰原照片。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.appDelegate?.removePet(id: id)
            self?.reload()
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "没能加入这张照片"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func togglePause(_ sender: NSButton) {
        appDelegate?.isPaused.toggle()
        sender.title = appDelegate?.isPaused == true ? "继续爬行" : "暂停爬行"
        appDelegate?.rebuildStatusMenu()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

// MARK: - App lifecycle and menu bar

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = PetStore()
    let bubbleSettings = BubbleSettings()
    var manager: ManagerWindowController!
    var petWindows: [UUID: PetWindow] = [:]
    var statusItem: NSStatusItem!
    var animationTimer: Timer?
    var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        manager = ManagerWindowController(store: store, bubbleSettings: bubbleSettings)
        manager.appDelegate = self
        setupMainMenu()
        setupStatusItem()
        for pet in store.pets where pet.isVisible { addPetWindow(for: pet) }
        configureAnimationTimer()
        manager.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureAnimationTimer() {
        animationTimer?.invalidate()
        let fps = clamp(bubbleSettings.animationFPS, 15, 60)
        animationTimer = Timer(timeInterval: 1.0/Double(fps), repeats: true) { [weak self] _ in
            guard let self else { return }
            for window in self.petWindows.values { window.tick(globalPaused: self.isPaused) }
        }
        animationTimer?.tolerance = (1.0 / Double(fps)) * 0.08
        RunLoop.main.add(animationTimer!, forMode: .common)
        for window in petWindows.values { window.resetAnimationClock() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        animationTimer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showManager() }
        return true
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Hej’s Pets")
        appMenuItem.submenu = appMenu

        let openItem = appMenu.addItem(withTitle: "打开宠物屋", action: #selector(showManager), keyEquivalent: "o")
        openItem.target = self
        let addItem = appMenu.addItem(withTitle: "添加照片…", action: #selector(addFromMenu), keyEquivalent: "n")
        addItem.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "退出 Hej’s Pets", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Hej’s Pets")
            button.imagePosition = .imageLeading
            button.title = "Hej’s Pets"
            button.font = .systemFont(ofSize: 12, weight: .semibold)
        }
        rebuildStatusMenu()
    }

    func rebuildStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开宠物屋", action: #selector(showManager), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "添加照片…", action: #selector(addFromMenu), keyEquivalent: "n").target = self
        menu.addItem(.separator())
        let pauseTitle = isPaused ? "继续爬行" : "暂停爬行"
        menu.addItem(withTitle: pauseTitle, action: #selector(togglePauseFromMenu), keyEquivalent: "p").target = self
        let anyVisible = !petWindows.isEmpty
        menu.addItem(withTitle: anyVisible ? "暂时隐藏全部" : "显示全部", action: #selector(toggleAll), keyEquivalent: "h").target = self
        menu.addItem(.separator())
        let about = NSMenuItem(title: "Hej 制作 · 本地轻量版", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(withTitle: "退出 Hej’s Pets", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    func addPetWindow(for record: PetRecord) {
        guard petWindows[record.id] == nil else { return }
        let window = PetWindow(
            record: record,
            imageURL: store.imageURL(for: record),
            headURL: store.headURL(for: record),
            clothingTextureURL: store.clothingTextureURL(for: record),
            bubbleSettings: bubbleSettings
        )
        petWindows[record.id] = window
        window.orderFrontRegardless()
        rebuildStatusMenu()
    }

    func removePet(id: UUID) {
        petWindows[id]?.orderOut(nil)
        petWindows[id]?.close()
        petWindows.removeValue(forKey: id)
        store.remove(id: id)
        rebuildStatusMenu()
    }

    func setPetVisible(id: UUID, visible: Bool) {
        store.setVisible(id: id, visible: visible)
        if visible, let record = store.pets.first(where: { $0.id == id }) {
            addPetWindow(for: record)
        } else {
            petWindows[id]?.orderOut(nil)
            petWindows[id]?.close()
            petWindows.removeValue(forKey: id)
        }
        rebuildStatusMenu()
    }

    func refreshPetWindow(id: UUID) {
        petWindows[id]?.orderOut(nil)
        petWindows[id]?.close()
        petWindows.removeValue(forKey: id)
        if let record = store.pets.first(where: { $0.id == id }), record.isVisible {
            addPetWindow(for: record)
        }
    }

    func applyUpdatedSettings() {
        configureAnimationTimer()
        for window in petWindows.values { window.resetBubbleSchedule() }
        rebuildStatusMenu()
    }

    @objc private func showManager() {
        manager.reload()
        manager.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        manager.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func addFromMenu() {
        showManager()
        manager.choosePhotos()
    }

    @objc private func togglePauseFromMenu() {
        isPaused.toggle()
        rebuildStatusMenu()
    }

    @objc private func toggleAll() {
        if petWindows.isEmpty {
            for pet in store.pets { setPetVisible(id: pet.id, visible: true) }
        } else {
            for pet in store.pets { setPetVisible(id: pet.id, visible: false) }
        }
        manager.reload()
        rebuildStatusMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct HejPetsApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
