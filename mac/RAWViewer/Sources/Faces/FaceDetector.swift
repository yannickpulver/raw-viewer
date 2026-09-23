import CoreGraphics
import Foundation
import Vision

/// One detected face on an upright image.
public struct Face: Codable, Equatable, Sendable {
    /// Normalised to `0...1`, origin bottom-left (Vision's convention), so it stays valid when a
    /// bigger develop of the same image replaces the preview.
    public var rect: CGRect
    /// Vision's capture quality, `0...1`, higher is sharper / better lit. `nil` when Vision
    /// returned none.
    public var quality: Float?
    public var eyesClosed: Bool

    public init(rect: CGRect, quality: Float?, eyesClosed: Bool) {
        self.rect = rect
        self.quality = quality
        self.eyesClosed = eyesClosed
    }
}

/// Vision face detection. Synchronous: call it off the main thread (`FaceIndex` does).
public struct FaceDetector: Sendable {
    /// An eye whose contour is flatter than this (height / width) counts as closed. Vision has
    /// no blink API, so this is a heuristic to be tuned against real shoots.
    public static let closedEyeRatio: CGFloat = 0.18
    /// Faces smaller than this on their short edge, in pixels of the analysed image, are noise
    /// (crowds, posters) and would only produce unusable crops.
    public static let minFacePixels: CGFloat = 16
    /// Bump whenever detection changes, so cached results from the old detector are dropped.
    public static let version = 4

    /// Tile grids run after the whole image: `count` x `count` tiles, each covering `share` of the
    /// width and height. 2 x 2 at 0.6 overlap by 20 %, 3 x 3 at 0.4 by 10 %.
    static let grids: [(count: Int, share: CGFloat)] = [(2, 0.6), (3, 0.4)]
    /// Crops around a face found only once, as multiples of its size, for the second look.
    static let confirmScales: [CGFloat] = [2, 3, 5]

    public init() {}

    /// Several passes, merged. Vision scales its input to a fixed size before detecting, so what
    /// counts is a face's size relative to the searched area, not the pixel count (full
    /// resolution found nothing more). Measured on a real shoot of 105 images:
    /// - the whole image: 29 faces
    /// - 2 x 2 tiles: 21 more; 3 x 3 tiles: 12 more (two people 20 px tall)
    /// - the head of every person Vision sees: 8 more (profiles, a face behind a camera)
    /// Found by one pass only, a face must show up again in a crop around it: that dropped all
    /// three false hits (a dark gap between two heads, a blurred figure, the back of a head)
    /// and none of the nine real faces found just once.
    public func detect(in image: CGImage) -> [Face] {
        let size = CGSize(width: image.width, height: image.height)
        var found: [(face: Face, hits: Int)] = []
        func add(_ faces: [Face], from area: CGRect) {
            for face in faces {
                let rect = Self.map(face.rect, from: area, in: size)
                if let index = found.firstIndex(where: { Self.isSameFace($0.face.rect, rect) }) {
                    found[index].hits += 1
                } else {
                    found.append((Face(rect: rect, quality: face.quality, eyesClosed: face.eyesClosed), 1))
                }
            }
        }

        let whole = CGRect(origin: .zero, size: size)
        add(detectWhole(image), from: whole)
        let areas = Self.grids.flatMap { Self.tiles(for: size, count: $0.count, share: $0.share) }
            + personHeads(in: image)
        for area in areas {
            guard let part = image.cropping(to: area) else { continue }
            add(detectWhole(part), from: area)
        }
        return found.filter { $0.hits > 1 || confirm($0.face.rect, in: image) }.map(\.face)
    }

    /// A square around the head of every person Vision finds, in pixels, top-left origin. A
    /// head fills far more of that square than of a tile, so turned or half-covered faces
    /// show up.
    func personHeads(in image: CGImage) -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { person in
            let body = person.boundingBox
            let side = max(body.width * size.width, body.height * size.height * 0.35) * 1.2
            let square = CGRect(x: body.midX * size.width - side / 2,
                                y: (1 - body.maxY) * size.height - side * 0.15,
                                width: side, height: side)
                .intersection(CGRect(origin: .zero, size: size)).integral
            return square.width > Self.minFacePixels ? square : nil
        }
    }

    /// Looks again in crops around `rect`, with both Vision face detectors.
    private func confirm(_ rect: CGRect, in image: CGImage) -> Bool {
        let size = CGSize(width: image.width, height: image.height)
        return Self.confirmScales.contains { scale in
            let side = max(rect.width * size.width, rect.height * size.height) * scale
            let square = CGRect(x: rect.midX * size.width - side / 2, y: (1 - rect.midY) * size.height - side / 2,
                                width: side, height: side)
                .intersection(CGRect(origin: .zero, size: size)).integral
            guard let part = image.cropping(to: square) else { return false }
            let rectangles = VNDetectFaceRectanglesRequest()
            let landmarks = VNDetectFaceLandmarksRequest()
            try? VNImageRequestHandler(cgImage: part, orientation: .up).perform([rectangles])
            try? VNImageRequestHandler(cgImage: part, orientation: .up).perform([landmarks])
            return ((rectangles.results ?? []) + (landmarks.results ?? [])).contains {
                Self.isSameFace(Self.map($0.boundingBox, from: square, in: size), rect)
            }
        }
    }

    /// A `count` x `count` grid of tile rects in pixels, top-left origin (what
    /// `CGImage.cropping` takes), row by row, spread evenly from edge to edge.
    static func tiles(for size: CGSize, count: Int, share: CGFloat) -> [CGRect] {
        let width = size.width * share, height = size.height * share
        let step = CGSize(width: (size.width - width) / CGFloat(max(1, count - 1)),
                          height: (size.height - height) / CGFloat(max(1, count - 1)))
        return (0..<count).flatMap { row in
            (0..<count).map { column in
                CGRect(x: CGFloat(column) * step.width, y: CGFloat(row) * step.height,
                       width: width, height: height).integral
            }
        }
    }

    /// A rect normalised to `tile` (bottom-left origin) as a rect normalised to the whole image.
    static func map(_ rect: CGRect, from tile: CGRect, in size: CGSize) -> CGRect {
        let top = tile.minY + (1 - rect.maxY) * tile.height
        let height = rect.height * tile.height
        return CGRect(x: (tile.minX + rect.minX * tile.width) / size.width,
                      y: 1 - (top + height) / size.height,
                      width: rect.width * tile.width / size.width,
                      height: height / size.height)
    }

    /// Half of the smaller box inside the other one. Looser than `overlap`, so a face cut by a
    /// tile edge still matches the whole face found elsewhere.
    static func isSameFace(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && intersection.width * intersection.height / smaller > 0.5
    }

    private func detectWhole(_ image: CGImage) -> [Face] {
        // Two detections on purpose, each on its own handler. The rectangles request finds more
        // faces (profiles, blurry ones), which is what culling needs. The landmarks request gets
        // a handler of its own because a handler caches face detection, and landmarks computed
        // on top of a cached rectangles result lose lowered lids (a face looking down measured
        // 0.15 on its own and 0.33 after the rectangles request).
        let rectangles = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do { try handler.perform([rectangles]) } catch { return [] }
        let size = CGSize(width: image.width, height: image.height)
        let observations = (rectangles.results ?? []).filter {
            min($0.boundingBox.width * size.width, $0.boundingBox.height * size.height) >= Self.minFacePixels
        }
        // Most tiles hold no face, so the costlier requests only run once one was found.
        guard !observations.isEmpty else { return [] }
        let landmarks = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([landmarks])

        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = observations
        try? handler.perform([quality])
        let scored = quality.results ?? []
        let landmarked = landmarks.results ?? []

        return observations.enumerated().map { index, observation in
            // Matched by uuid, with the input order as the fallback should Vision hand back copies.
            let withQuality = scored.first { $0.uuid == observation.uuid }
                ?? (scored.count == observations.count ? scored[index] : nil)
            let withLandmarks = landmarked
                .map { ($0, Self.overlap($0.boundingBox, observation.boundingBox)) }
                .filter { $0.1 >= 0.3 }
                .max { $0.1 < $1.1 }?.0
            return Face(rect: observation.boundingBox,
                        quality: withQuality?.faceCaptureQuality,
                        eyesClosed: Self.eyesClosed(withLandmarks?.landmarks, imageSize: size))
        }
    }

    /// Intersection over union of two normalised rects.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let shared = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - shared
        return union > 0 ? shared / union : 0
    }

    /// Closed only when both eyes are, so a wink or one unreliable contour does not flag a face.
    static func eyesClosed(_ landmarks: VNFaceLandmarks2D?, imageSize: CGSize) -> Bool {
        guard let left = landmarks?.leftEye?.pointsInImage(imageSize: imageSize),
              let right = landmarks?.rightEye?.pointsInImage(imageSize: imageSize),
              let leftRatio = openness(left), let rightRatio = openness(right) else { return false }
        return leftRatio < closedEyeRatio && rightRatio < closedEyeRatio
    }

    /// Height / width of an eye contour, measured in image pixels so the face box's aspect does
    /// not skew it. `nil` for a degenerate contour.
    static func openness(_ points: [CGPoint]) -> CGFloat? {
        guard points.count >= 3,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              maxX - minX > 0 else { return nil }
        return (maxY - minY) / (maxX - minX)
    }
}
