import Foundation

/// Removes physiological FDG uptake (brain, urinary bladder, heart wall,
/// kidneys, etc.) from a PET lesion mask by subtracting an anatomical
/// mask produced by TotalSegmentator or any other whole-body CT organ
/// model.
///
/// Why this is needed: AutoPET-style lesion models occasionally flag
/// physiological uptake — bright brain cortex, voided bladder, myocardial
/// wall, hot kidneys — as "lesion". A radiologist wants those voxels
/// suppressed in the output so the TMTV and per-lesion stats don't get
/// biased by uptake the model shouldn't have highlighted.
///
/// The expected workflow is:
///
/// 1. Run TotalSegmentator (or any `NNUnetCatalog` CT organ model) on the
///    co-registered CT → produces an anatomy label map.
/// 2. Map the anatomical class names we care about (brain, bladder, heart,
///    kidneys, liver) to their class ids.
/// 3. Pass both label maps + the ids-to-suppress to
///    `PhysiologicalUptakeFilter.subtract(...)`.
public enum PhysiologicalUptakeFilter {

    public struct SuppressionResult {
        public let voxelsSuppressed: Int
        public let classesSuppressed: [String]
    }

    /// Default set of physiological-uptake organ names that should be
    /// suppressed from a whole-body FDG lesion mask. Matches
    /// TotalSegmentator's class names.
    public static let defaultSuppressedOrganNames: [String] = [
        "brain",
        "urinary_bladder",
        "kidney_left", "kidney_right",
        "heart",
        "spleen",       // baseline FDG uptake reference, not lesion
        "liver",        // physiological reference; often used for Deauville
    ]

    /// Zero out every voxel in `petLesionMask` where `anatomyMask` reports
    /// one of the suppressed organs. Mutates `petLesionMask` in place and
    /// returns a summary of how much was removed.
    @discardableResult
    public static func subtract(petLesionMask: LabelMap,
                                anatomyMask: LabelMap,
                                suppressedOrganNames: [String] = defaultSuppressedOrganNames,
                                dilationIterations: Int = 1) -> SuppressionResult {
        precondition(petLesionMask.width == anatomyMask.width
                     && petLesionMask.height == anatomyMask.height
                     && petLesionMask.depth == anatomyMask.depth,
                     "PhysiologicalUptakeFilter: mask dimensions must match")

        // Resolve names → class ids in the anatomy map.
        let lowered = Set(suppressedOrganNames.map { $0.lowercased() })
        let suppressedIDs: Set<UInt16> = Set(
            anatomyMask.classes
                .filter { lowered.contains($0.name.lowercased()) }
                .map(\.labelID)
        )
        let suppressedNames = anatomyMask.classes
            .filter { suppressedIDs.contains($0.labelID) }
            .map(\.name)

        guard !suppressedIDs.isEmpty else {
            return SuppressionResult(voxelsSuppressed: 0, classesSuppressed: [])
        }

        // Optionally dilate the anatomy mask so we include a small margin
        // around each organ — useful because bladder/heart wall signal
        // can bleed a few mm outside the segmentation.
        var suppression: [Bool] = anatomyMask.voxels.map { suppressedIDs.contains($0) }
        if dilationIterations > 0 {
            suppression = dilate(mask: suppression,
                                  width: anatomyMask.width,
                                  height: anatomyMask.height,
                                  depth: anatomyMask.depth,
                                  iterations: dilationIterations)
        }

        var removed = 0
        for i in 0..<petLesionMask.voxels.count {
            if suppression[i], petLesionMask.voxels[i] != 0 {
                petLesionMask.voxels[i] = 0
                removed += 1
            }
        }
        petLesionMask.objectWillChange.send()

        return SuppressionResult(voxelsSuppressed: removed,
                                 classesSuppressed: suppressedNames.sorted())
    }

    // MARK: - 6-connected binary dilation

    private static func dilate(mask: [Bool],
                               width w: Int, height h: Int, depth d: Int,
                               iterations: Int) -> [Bool] {
        guard iterations > 0 else { return mask }
        var current = mask
        var next = mask
        for _ in 0..<iterations {
            for z in 0..<d {
                for y in 0..<h {
                    for x in 0..<w {
                        let i = z * h * w + y * w + x
                        if current[i] { next[i] = true; continue }
                        if (x > 0     && current[i - 1])
                            || (x < w - 1 && current[i + 1])
                            || (y > 0     && current[i - w])
                            || (y < h - 1 && current[i + w])
                            || (z > 0     && current[i - w * h])
                            || (z < d - 1 && current[i + w * h]) {
                            next[i] = true
                        }
                    }
                }
            }
            current = next
        }
        return current
    }
}
