import CoreGraphics

/// Groups text fragments (boxes in pixels, any origin) into left-to-right runs that sit on the same
/// line with no more than a word space between them. `isGlued` marks a fragment that touches the
/// previous one, i.e. the split fell inside a word.
func fragmentRuns(_ boxes: [CGRect]) -> [[(index: Int, isGlued: Bool)]] {
    var runs: [[(index: Int, isGlued: Bool)]] = []
    for index in boxes.indices.sorted(by: { boxes[$0].minX < boxes[$1].minX }) {
        let box = boxes[index]
        var closest: (run: Int, gap: CGFloat, height: CGFloat)?
        for (runIndex, run) in runs.enumerated() {
            guard let last = run.last.map({ boxes[$0.index] }) else { continue }
            let height = max(last.height, box.height)
            let sharedHeight = min(last.maxY, box.maxY) - max(last.minY, box.minY)
            let gap = box.minX - last.maxX
            guard sharedHeight >= 0.5 * min(last.height, box.height), gap >= -0.5 * height, gap <= 1.2 * height else { continue }
            if closest.map({ abs(gap) < abs($0.gap) }) ?? true { closest = (runIndex, gap, height) }
        }
        if let closest {
            runs[closest.run].append((index, closest.gap < 0.15 * closest.height))
        } else {
            runs.append([(index, false)])
        }
    }
    return runs
}

/// Concatenates the fragments of a run, with a space unless a fragment is glued to the previous one.
/// `offsets` is where each fragment starts in the result, in characters.
func joinFragments(_ parts: [(text: String, isGlued: Bool)]) -> (text: String, offsets: [Int]) {
    var text = ""
    var offsets: [Int] = []
    for (position, part) in parts.enumerated() {
        if position > 0, !part.isGlued { text += " " }
        offsets.append(text.count)
        text += part.text
    }
    return (text, offsets)
}
