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
        if let firstNifti = niftiSeries.first {
            return try loadNIfTI(study: study, series: firstNifti)
        }
        throw LoadError.emptyStudy
    }

    // MARK: - DICOM

    private static func loadDICOM(study: PACSWorklistStudy,
                                  series: [PACSIndexedSeriesSnapshot]) throws -> LoadedStudy {
        let ctSeries = series.first { Modality.normalize($0.modality) == .CT }
        let petSeries = series.first { Modality.normalize($0.modality) == .PT }

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
                                  series: PACSIndexedSeriesSnapshot) throws -> LoadedStudy {
        let path = series.filePaths.first ?? series.sourcePath
        guard !path.isEmpty else {
            throw LoadError.niftiLoadFailed("NIfTI series has no file path")
        }
        do {
            let url = URL(fileURLWithPath: path)
            let vol = try NIfTILoader.load(url, modalityHint: series.modality)
            return LoadedStudy(primary: vol, auxiliary: [])
        } catch {
            throw LoadError.niftiLoadFailed(error.localizedDescription)
        }
    }
}
