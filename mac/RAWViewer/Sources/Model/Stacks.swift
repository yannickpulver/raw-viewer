import Foundation

/// Multi-exposure stacks: the frames of one bracket (HDR, exposure blending). Mac app
/// addition, no Python-app equivalent. Cameras mark their brackets inconsistently (the
/// Mavic 3 Pro writes "Manual"), so the rule only looks at time and exposure compensation: a
/// frame joins the previous one's stack when it was shot at most `maxGap` later on the same
/// camera and its EV differs from every frame already in the stack. Shutter time alone does
/// not count: in auto exposure it drifts between burst frames (1/100 → 1/105 at the same
/// +0.33 EV). A burst therefore stays single frames, and back-to-back brackets split where the
/// EV repeats.
public enum Stacks {
    public static let maxGap: TimeInterval = 1

    /// The ranges of `files` that form a stack (two frames or more), in timeline order. Works
    /// on either date order.
    public static func ranges(in files: [MediaFile], maxGap: TimeInterval = Stacks.maxGap) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var biases: Set<Double> = []
        for index in files.indices {
            let file = files[index]
            let previous = index > start ? files[index - 1] : nil
            if let previous, previous.exposure != nil, previous.kind != .video,
               let exposure = file.exposure, file.kind != .video,
               file.subfolder == previous.subfolder,
               abs(file.captureDate.timeIntervalSince(previous.captureDate)) <= maxGap,
               !biases.contains(exposure.bias) {
                biases.insert(exposure.bias)
                continue
            }
            if index - start > 1 { ranges.append(start..<index) }
            start = index
            biases = file.exposure.map { [$0.bias] } ?? []
        }
        if files.count - start > 1 { ranges.append(start..<files.count) }
        return ranges
    }

    /// The frame that stands for the stack: the one closest to 0 EV, the earliest on a tie.
    public static func cover(of members: [MediaFile]) -> MediaFile {
        func distance(_ file: MediaFile) -> Double { abs(file.exposure?.bias ?? 0) }
        var best = members[0]
        for member in members.dropFirst() where distance(member) < distance(best) { best = member }
        return best
    }
}
