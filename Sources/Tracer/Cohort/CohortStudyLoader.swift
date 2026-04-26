import Foundation

/// Produces `ImageVolume`s from a `PACSWorklistStudy` without touching the
/// main-actor-bound `ViewerViewModel`. Cohort jobs run on a background
/// actor, so they need a Sendable, re-entrant loader.
///
/// Strategy per study:
///   • NIfTI: load the first (and usually only) series' first file.
///   • DICOM with PET + CT: load both; return CT as primary, PET as
///     auxiliary channel[0]. Most nnU-Net PET models expect `(CT, PET)` in
///     that channel order.
///   • DICOM with a single modality: load just that.
enum CohortStudyLoader {

    struct LoadedStudy: Sendable {
        var primary: ImageVolume
        /// Auxiliary channels for multi-channel nnU-Net models. Empty for
        /// single-channel inputs. Channel 0 here becomes nnU-Net's
        /// channel 1 (primary is always channel 0).
        var auxiliary: [ImageVolume]

        var allVolumes: [ImageVolume] { [primary] + auxiliary }

        /// PET-aware volume for TMTV / SUV stats. When a PET channel exists
        /// we convert it to SUV once so both quantification and PET-based
        /// classifiers see the same intensities.
        var quantificationVolume: ImageVolume {
            classificationVolume(for: .PT) ?? primary
        }

        func volume(for modality: Modality) -> ImageVolume? {
            allVolumes.first { Modality.normalize($0.modality) == modality }
        }

        func classificationVolume(for modality: Modality?) -> ImageVolume? {
            guard let modality else { return primary }
            guard let match = volume(for: modality) else { return nil }
            if modality == .PT {
                return CohortStudyLoader.makePETSUVVolume(match)
            }
            return match
        }

        func segmentationChannels(for entry: NNUnetCatalog.Entry) -> [ImageVolume] {
            let channels = allVolumes
            guard case .petSUV = entry.preprocessing else { return channels }
            return channels.map(CohortStudyLoader.makePETSUVVolume)
        }

        /// Returns a new `LoadedStudy` with the PET channel replaced by the
        /// supplied AC PET. Used by the cohort AC step to swap the corrected
        /// PET into the load set so downstream segmentation + quantification
        /// + classification all see the AC values.
        ///
        /// Channel placement:
        ///   • If the primary is PET (PET-only studies) → replace primary
        ///   • Else → replace the first auxiliary PET (PET/CT case where
        ///     CT is primary and PET is auxiliary[0])
        ///   • If no PET channel is found at all (defensive — caller should
        ///     have validated before calling AC) → return self unchanged.
        func replacingPET(with acVolume: ImageVolume) -> LoadedStudy {
            if Modality.normalize(primary.modality) == .PT {
                return LoadedStudy(primary: acVolume, auxiliary: auxiliary)
            }
            if let petIdx = auxiliary.firstIndex(where: {
                Modality.normalize($0.modality) == .PT
            }) {
                var newAux = auxiliary
                newAux[petIdx] = acVolume
                return LoadedStudy(primary: primary, auxiliary: newAux)
            }
            return self
        }
    }

    enum LoadError: Swift.Error, LocalizedError {
        case emptyStudy
        case dicomLoadFailed(String)
        case niftiLoadFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyStudy:            return "Study has no series to load."
            case .dicomLoadFailed(let m): return "DICOM load failed: \(m)"
            case .niftiLoadFailed(let m): return "NIfTI load failed: \(m)"
            }
        }
    }

    static func load(_ study: PACSWorklistStudy) throws -> LoadedStudy {
        guard !study.series.isEmpty else { throw LoadError.emptyStudy }

        // Partition by kind. Cohort usually sees a single kind per study
        // but the worklist type allows mixing, so we handle both.
        let dicomSeries = study.series.filter { $0.kind == .dicom }
        let niftiSeries = study.series.filter { $0.kind == .nifti }

        if !dicomSeries.isEmpty {
            return try loadDICOM(study: study, series: dicomSeries)
        }
        if !niftiSeries.isEmpty {
            return try loadNIfTI(study: study, series: niftiSeries)
        }
        throw LoadError.emptyStudy
    }

    static func makePETSUVVolume(_ volume: ImageVolume) -> ImageVolume {
        guard Modality.normalize(volume.modality) == .PT,
              let scale = volume.suvScaleFactor else {
            return volume
        }

        let scaledPixels = volume.pixels.map { $0 * Float(scale) }
        return ImageVolume(
            pixels: scaledPixels,
            depth: volume.depth,
            height: volume.height,
            width: volume.width,
            spacing: volume.spacing,
            origin: volume.origin,
            direction: volume.direction,
            modality: volume.modality,
            seriesUID: volume.seriesUID,
            studyUID: volume.studyUID,
            patientID: volume.patientID,
            patientName: volume.patientName,
            seriesDescription: volume.seriesDescription.isEmpty
                ? "PET SUV input"
                : "\(volume.seriesDescription) (SUV input)",
            studyDescription: volume.studyDescription,
            suvScaleFactor: nil,
            sourceFiles: volume.sourceFiles
        )
    }

    // MARK: - DICOM

    private static func loadDICOM(study: PACSWorklistStudy,
                                  series: [PACSIndexedSeriesSnapshot]) throws -> LoadedStudy {
        let ctSeries = PACSWorklistStudy.preferredAnatomicalSeriesForPETCT(in: series)
        let petSeries = PACSWorklistStudy.preferredPETSeriesForPETCT(in: series)

        // PET/CT → CT is the anatomic reference (primary), PET is aux ch 0.
        if let ctSeries, let petSeries {
            let ct = try loadDICOMSeries(snapshot: ctSeries)
            let pet = try loadDICOMSeries(snapshot: petSeries)
            return LoadedStudy(primary: ct, auxiliary: [pet])
        }

        // Single-modality DICOM — load whichever series we have, preferring
        // CT/MR/PT in that order as the primary.
        let preferredOrder: [Modality] = [.CT, .MR, .PT, .OT]
        for modality in preferredOrder {
            if let match = series.first(where: { Modality.normalize($0.modality) == modality }) {
                let vol = try loadDICOMSeries(snapshot: match)
                return LoadedStudy(primary: vol, auxiliary: [])
            }
        }
        // Fallback — whatever's first.
        let vol = try loadDICOMSeries(snapshot: series[0])
        return LoadedStudy(primary: vol, auxiliary: [])
    }

    private static func loadDICOMSeries(snapshot: PACSIndexedSeriesSnapshot) throws -> ImageVolume {
        do {
            // Parse every file in the series and hand them to the existing
            // loader. parseHeader is idempotent + safe to re-read — mirrors
            // what ViewerViewModel.openIndexedDICOMSeries does, minus the UI.
            var files: [DICOMFile] = []
            files.reserveCapacity(snapshot.filePaths.count)
            for path in snapshot.filePaths {
                let url = URL(fileURLWithPath: path)
                if let f = try? DICOMLoader.parseHeader(at: url) {
                    files.append(f)
                }
            }
            guard !files.isEmpty else {
                throw LoadError.dicomLoadFailed("no readable DICOM files for series \(snapshot.seriesUID)")
            }
            return try DICOMLoader.loadSeries(files)
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.dicomLoadFailed(error.localizedDescription)
        }
    }

    // MARK: - NIfTI

    private static func loadNIfTI(study: PACSWorklistStudy,
                                  series: [PACSIndexedSeriesSnapshot]) throws -> LoadedStudy {
        let ctSeries = PACSWorklistStudy.preferredAnatomicalSeriesForPETCT(in: series)
        let petSeries = PACSWorklistStudy.preferredPETSeriesForPETCT(in: series)

        // NIfTI PET/CT archives such as AutoPET often store CT, CTres,
        // PET, SUV, and SEG side by side. Treat CTres + SUV as the model
        // input pair when available, and keep SEG out of imaging channels.
        if let ctSeries, let petSeries {
            let ct = try loadNIfTISeries(snapshot: ctSeries)
            let pet = try loadNIfTISeries(snapshot: petSeries)
            return LoadedStudy(primary: ct, auxiliary: [pet])
        }

        guard let primary = PACSWorklistStudy.preferredPrimaryImageSeries(in: series) else {
            throw LoadError.emptyStudy
        }
        let vol = try loadNIfTISeries(snapshot: primary)
        return LoadedStudy(primary: vol, auxiliary: [])
    }

    private static func loadNIfTISeries(snapshot: PACSIndexedSeriesSnapshot) throws -> ImageVolume {
        let path = snapshot.filePaths.first ?? snapshot.sourcePath
        guard !path.isEmpty else {
            throw LoadError.niftiLoadFailed("NIfTI series has no file path")
        }
        do {
            let url = URL(fileURLWithPath: path)
            return try NIfTILoader.load(url, modalityHint: snapshot.modality)
        } catch {
            throw LoadError.niftiLoadFailed(error.localizedDescription)
        }
    }
}
