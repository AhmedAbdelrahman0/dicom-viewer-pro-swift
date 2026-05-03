import XCTest
import SwiftUI
@testable import Tracer

final class NeuroQuantificationWorkbenchTests: XCTestCase {
    func testLockedWorkflowConfigurationFindsProtocolRegions() {
        let atlas = makeCentiloidAtlas()
        let validation = NeuroQuantAtlasRegistry.bestValidation(for: atlas, workflow: .amyloidCentiloid)
        let configuration = NeuroQuantWorkflowProtocol.amyloidCentiloid.configuration(
            atlas: atlas,
            normalDatabase: nil
        )

        XCTAssertEqual(NeuroQuantWorkflowProtocol.amyloidCentiloid.tracer.family, .amyloid)
        XCTAssertEqual(NeuroQuantWorkflowProtocol.amyloidCentiloid.preferredTemplateSpace, .centiloid)
        XCTAssertTrue(validation.isUsable)
        XCTAssertFalse(configuration.referenceClassIDs.isEmpty)
        XCTAssertFalse(configuration.targetClassIDs.isEmpty)
        XCTAssertTrue(NeuroQuantWorkflowProtocol.amyloidCentiloid.reportSections.contains("Centiloid"))
    }

    func testWorkbenchBuildsZMapClustersProjectionsAndReport() throws {
        let volume = ImageVolume(
            pixels: [
                0.4, 0.4,
                1.0, 1.0
            ],
            depth: 1,
            height: 2,
            width: 2,
            modality: "PT",
            seriesDescription: "FDG brain PET"
        )
        let atlas = LabelMap(
            parentSeriesUID: volume.seriesUID,
            depth: 1,
            height: 2,
            width: 2,
            name: "FDG dementia atlas",
            classes: [
                LabelClass(labelID: 1, name: "Temporal cortex", category: .brain, color: .orange),
                LabelClass(labelID: 2, name: "Parietal cortex", category: .brain, color: .blue),
                LabelClass(labelID: 3, name: "Pons", category: .brain, color: .green)
            ]
        )
        atlas.voxels = [
            1, 1,
            2, 3
        ]
        let normals = BrainPETNormalDatabase(
            id: "fdg-test",
            name: "FDG test normals",
            tracer: .fdg,
            referenceRegion: "Pons",
            sourceDescription: "unit test",
            entries: [
                .init(regionName: "Temporal cortex", labelID: 1, meanSUVR: 1.0, sdSUVR: 0.2, sampleSize: 20),
                .init(regionName: "Parietal cortex", labelID: 2, meanSUVR: 1.0, sdSUVR: 0.2, sampleSize: 20)
            ]
        )

        let result = try NeuroQuantWorkbench.run(
            volume: volume,
            atlas: atlas,
            normalDatabase: normals,
            workflow: .fdgDementia,
            anatomyVolume: nil,
            anatomyMode: .petOnly
        )

        XCTAssertEqual(result.report.family, .fdg)
        XCTAssertEqual(result.zScoreMap.values[0], -3, accuracy: 1e-6)
        XCTAssertEqual(result.clusters.count, 1)
        XCTAssertEqual(result.clusters.first?.voxelCount, 2)
        XCTAssertEqual(result.clusters.first?.dominantRegion, "Temporal cortex")
        XCTAssertEqual(result.surfaceProjections.count, 6)
        XCTAssertTrue(result.structuredReport.impression.contains("Temporal cortex"))
        XCTAssertEqual(result.clinicalReadiness.status, .validationPending)
        XCTAssertTrue(result.clinicalReadiness.warnings.contains { $0.contains("No local validation") })
    }

    func testDaTscanWorkflowComputesStriatalBindingMetrics() throws {
        let volume = ImageVolume(
            pixels: [4, 5, 3, 2, 1],
            depth: 1,
            height: 1,
            width: 5,
            modality: "NM",
            seriesDescription: "DaTscan SPECT"
        )
        let atlas = LabelMap(
            parentSeriesUID: volume.seriesUID,
            depth: 1,
            height: 1,
            width: 5,
            name: "DaTscan striatal atlas",
            classes: [
                LabelClass(labelID: 1, name: "Left caudate", category: .brain, color: .orange),
                LabelClass(labelID: 2, name: "Right caudate", category: .brain, color: .orange),
                LabelClass(labelID: 3, name: "Left putamen", category: .brain, color: .blue),
                LabelClass(labelID: 4, name: "Right putamen", category: .brain, color: .blue),
                LabelClass(labelID: 5, name: "Occipital background", category: .brain, color: .green)
            ]
        )
        atlas.voxels = [1, 2, 3, 4, 5]

        let result = try NeuroQuantWorkbench.run(
            volume: volume,
            atlas: atlas,
            normalDatabase: nil,
            workflow: .datscanStriatal,
            anatomyVolume: nil,
            anatomyMode: .petOnly
        )

        let metrics = try XCTUnwrap(result.striatalMetrics)
        XCTAssertEqual(result.report.family, .dopamineTransporter)
        XCTAssertEqual(metrics.meanStriatalBindingRatio ?? 0, 3.5, accuracy: 1e-9)
        XCTAssertEqual(metrics.asymmetryPercent ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(metrics.putamenCaudateRatio ?? 0, 2.5 / 4.5, accuracy: 1e-9)
        XCTAssertTrue(result.structuredReport.plainText.contains("Mean striatal binding ratio"))
    }

    func testClinicalValidationPassesAndPromotesWorkbenchReadiness() throws {
        let atlas = makeCompleteCentiloidAtlas()
        let validationCases = (0..<20).map { index in
            NeuroQuantValidationCase(
                id: "case-\(index)",
                expectedValue: Double(index) + 10,
                observedValue: Double(index) + 11
            )
        }
        let validation = NeuroQuantClinicalValidationResult.evaluate(
            workflow: .amyloidCentiloid,
            metric: .centiloid,
            cases: validationCases,
            sourceDescription: "Local amyloid validation cohort"
        )
        let volume = ImageVolume(
            pixels: [1.4, 1.4, 1.4, 1.4, 1.4, 1.4, 1.0],
            depth: 1,
            height: 1,
            width: 7,
            modality: "PT",
            seriesDescription: "Amyloid validation PET"
        )

        let result = try NeuroQuantWorkbench.run(
            volume: volume,
            atlas: atlas,
            normalDatabase: nil,
            workflow: .amyloidCentiloid,
            anatomyVolume: nil,
            anatomyMode: .petOnly,
            localValidation: validation
        )

        XCTAssertTrue(validation.passed)
        XCTAssertEqual(validation.statistics.caseCount, 20)
        XCTAssertEqual(validation.statistics.rSquared, 1, accuracy: 1e-9)
        XCTAssertEqual(result.clinicalReadiness.status, .locallyValidated)
        XCTAssertTrue(result.structuredReport.plainText.contains("Clinical Readiness"))
        XCTAssertTrue(result.clinicalReadiness.evidenceLines.contains { $0.contains("Validation Centiloid") })
    }

    func testClinicalValidationFailureKeepsReadinessResearchOnly() throws {
        let validation = NeuroQuantClinicalValidationResult.evaluate(
            workflow: .amyloidCentiloid,
            metric: .centiloid,
            cases: [
                NeuroQuantValidationCase(id: "case-1", expectedValue: 10, observedValue: 20),
                NeuroQuantValidationCase(id: "case-2", expectedValue: 20, observedValue: 10)
            ],
            sourceDescription: "Too small validation cohort"
        )
        let atlas = makeCompleteCentiloidAtlas()
        let template = NeuroTemplateRegistrationPlan.make(
            volume: ImageVolume(pixels: [1, 1, 1, 1, 1, 1, 1], depth: 1, height: 1, width: 7, modality: "PT"),
            anatomyVolume: nil,
            atlasValidation: NeuroQuantAtlasRegistry.bestValidation(for: atlas, workflow: .amyloidCentiloid),
            workflow: .amyloidCentiloid
        )
        let readiness = NeuroQuantClinicalReadiness.evaluate(
            workflow: .amyloidCentiloid,
            atlasValidation: NeuroQuantAtlasRegistry.bestValidation(for: atlas, workflow: .amyloidCentiloid),
            normalDatabase: nil,
            templatePlan: template,
            localValidation: validation,
            referenceManifest: nil
        )

        XCTAssertFalse(validation.passed)
        XCTAssertTrue(validation.failures.contains { $0.contains("requires at least") })
        XCTAssertEqual(readiness.status, .researchOnly)
        XCTAssertTrue(readiness.blockers.contains { $0.contains("requires at least") })
    }

    func testRequiredNormalDatabaseBlocksFDGClinicalReadiness() throws {
        let atlas = LabelMap(
            parentSeriesUID: "fdg",
            depth: 1,
            height: 1,
            width: 3,
            name: "FDG atlas",
            classes: [
                LabelClass(labelID: 1, name: "Temporal cortex", category: .brain, color: .orange),
                LabelClass(labelID: 2, name: "Parietal cortex", category: .brain, color: .blue),
                LabelClass(labelID: 3, name: "Pons", category: .brain, color: .green)
            ]
        )
        atlas.voxels = [1, 2, 3]

        let result = try NeuroQuantWorkbench.run(
            volume: ImageVolume(pixels: [0.8, 0.9, 1.0], depth: 1, height: 1, width: 3, modality: "PT"),
            atlas: atlas,
            normalDatabase: nil,
            workflow: .fdgDementia,
            anatomyVolume: nil,
            anatomyMode: .petOnly
        )

        XCTAssertEqual(result.clinicalReadiness.status, .researchOnly)
        XCTAssertTrue(result.clinicalReadiness.blockers.contains { $0.contains("No matching normal database") })
    }

    func testLongitudinalComparisonFlagsAmyloidIncrease() throws {
        let atlas = makeCentiloidAtlas()
        let baseline = try BrainPETAnalysis.analyze(
            volume: ImageVolume(pixels: [1.1, 1.2, 1.0], depth: 1, height: 1, width: 3, modality: "PT"),
            atlas: atlas,
            configuration: NeuroQuantWorkflowProtocol.amyloidCentiloid.configuration(atlas: atlas, normalDatabase: nil)
        )
        let current = try BrainPETAnalysis.analyze(
            volume: ImageVolume(pixels: [1.5, 1.6, 1.0], depth: 1, height: 1, width: 3, modality: "PT"),
            atlas: atlas,
            configuration: NeuroQuantWorkflowProtocol.amyloidCentiloid.configuration(atlas: atlas, normalDatabase: nil)
        )

        let comparison = NeuroLongitudinalComparison.compare(
            baseline: baseline,
            current: current,
            workflow: .amyloidCentiloid
        )

        XCTAssertEqual(comparison.deltaTargetSUVR ?? 0, 0.4, accuracy: 1e-6)
        XCTAssertEqual(comparison.deltaCentiloid ?? 0, 75.288, accuracy: 0.001)
        XCTAssertEqual(comparison.progressionFlag, "Increasing binding")
        XCTAssertFalse(comparison.regionDeltas.isEmpty)
    }

    func testAtlasValidationWarnsWhenReferenceRegionsAreMissing() {
        let atlas = LabelMap(
            parentSeriesUID: "missing",
            depth: 1,
            height: 1,
            width: 1,
            name: "Incomplete atlas",
            classes: [
                LabelClass(labelID: 1, name: "Temporal cortex", category: .brain, color: .orange)
            ]
        )
        atlas.voxels = [1]

        let validation = NeuroQuantAtlasRegistry.bestValidation(for: atlas, workflow: .amyloidCentiloid)

        XCTAssertFalse(validation.isUsable)
        XCTAssertTrue(validation.warnings.contains { $0.contains("reference") })
        XCTAssertLessThan(validation.score, 1.0)
    }

    func testAUCDecisionSupportsAmyloidTherapyEligibilityAndMRISafetyWarning() {
        let intake = NeuroAUCIntake(
            questions: [.mildCognitiveImpairment, .antiAmyloidTherapyEligibility],
            treatmentEligibilityQuestion: true,
            hasRecentMRI: false
        )

        let decision = NeuroAUCDecisionSupport.evaluate(
            intake: intake,
            workflow: .amyloidCentiloid
        )

        XCTAssertEqual(decision.rating, .appropriate)
        XCTAssertEqual(decision.suggestedWorkflow, .amyloidCentiloid)
        XCTAssertTrue(decision.rationale.contains { $0.contains("treatment-selection") })
        XCTAssertTrue(decision.warnings.contains { $0.contains("recent MRI") })
    }

    func testDiseasePatternInterpreterFindsAlzheimerLikeFDGPattern() {
        let report = BrainPETReport(
            tracer: .fdg,
            family: .fdg,
            referenceRegionName: "Pons",
            referenceMean: 1,
            targetSUVR: 0.78,
            centiloid: nil,
            centiloidCalibrationName: nil,
            tauGrade: nil,
            regions: [
                BrainPETRegionStatistic(labelID: 1,
                                        name: "Precuneus cortex",
                                        voxelCount: 12,
                                        meanActivity: 0.68,
                                        suvr: 0.68,
                                        normalMeanSUVR: 1,
                                        normalSDSUVR: 0.1,
                                        zScore: -3.2),
                BrainPETRegionStatistic(labelID: 2,
                                        name: "Posterior cingulate cortex",
                                        voxelCount: 12,
                                        meanActivity: 0.7,
                                        suvr: 0.7,
                                        normalMeanSUVR: 1,
                                        normalSDSUVR: 0.1,
                                        zScore: -3.0),
                BrainPETRegionStatistic(labelID: 3,
                                        name: "Temporal cortex",
                                        voxelCount: 12,
                                        meanActivity: 0.75,
                                        suvr: 0.75,
                                        normalMeanSUVR: 1,
                                        normalSDSUVR: 0.1,
                                        zScore: -2.5)
            ],
            warnings: []
        )

        let patterns = NeuroDiseasePatternInterpreter.interpret(
            report: report,
            clusters: [],
            workflow: .fdgDementia
        )

        XCTAssertEqual(patterns.first?.kind, .alzheimerLike)
        XCTAssertTrue(patterns.first?.supportingRegions.contains("Precuneus cortex") == true)
        XCTAssertTrue(patterns.first?.confidence ?? 0 > 0.7)
    }

    func testMRIContextFlagsAntiAmyloidSafetyRisk() {
        let assessment = NeuroMRIContextAnalyzer.assess(
            input: NeuroMRIContextInput(
                hasT1: true,
                microhemorrhageCount: 12,
                superficialSiderosis: true,
                vascularBurden: .moderate
            ),
            workflow: .amyloidCentiloid,
            patterns: []
        )

        XCTAssertEqual(assessment.riskLevel, .high)
        XCTAssertTrue(assessment.warnings.contains { $0.contains("high-risk") })
        XCTAssertTrue(assessment.reportLines.contains { $0.contains("MRI context risk") })
    }

    func testDaTscanClinicalAssessmentFlagsPosteriorPutamenDropoff() throws {
        let volume = ImageVolume(
            pixels: [4, 4, 2, 2, 1],
            depth: 1,
            height: 1,
            width: 5,
            modality: "NM",
            seriesDescription: "DaTscan SPECT"
        )
        let atlas = LabelMap(
            parentSeriesUID: volume.seriesUID,
            depth: 1,
            height: 1,
            width: 5,
            name: "DaTscan striatal atlas",
            classes: [
                LabelClass(labelID: 1, name: "Left caudate", category: .brain, color: .orange),
                LabelClass(labelID: 2, name: "Right caudate", category: .brain, color: .orange),
                LabelClass(labelID: 3, name: "Left putamen", category: .brain, color: .blue),
                LabelClass(labelID: 4, name: "Right putamen", category: .brain, color: .blue),
                LabelClass(labelID: 5, name: "Occipital background", category: .brain, color: .green)
            ]
        )
        atlas.voxels = [1, 2, 3, 4, 5]

        let result = try NeuroQuantWorkbench.run(
            volume: volume,
            atlas: atlas,
            normalDatabase: nil,
            workflow: .datscanStriatal,
            anatomyVolume: nil,
            anatomyMode: .petOnly
        )

        let metrics = try XCTUnwrap(result.striatalMetrics)
        XCTAssertEqual(metrics.caudatePutamenDropoffPercent ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(result.datscanAssessment?.pattern, .bilateralPosteriorPutamenDeficit)
        XCTAssertTrue(result.structuredReport.plainText.contains("DaTscan Assessment"))
    }

    func testPerfusionAssessmentAndCVRComparisonSummarizeTerritories() {
        let baseline = BrainPETReport(
            tracer: .spectHMPAO,
            family: .spectPerfusion,
            referenceRegionName: "Whole brain",
            referenceMean: 1,
            targetSUVR: 0.82,
            centiloid: nil,
            centiloidCalibrationName: nil,
            tauGrade: nil,
            regions: [
                BrainPETRegionStatistic(labelID: 1,
                                        name: "Frontal cortex",
                                        voxelCount: 10,
                                        meanActivity: 0.8,
                                        suvr: 0.8,
                                        normalMeanSUVR: 1,
                                        normalSDSUVR: 0.1,
                                        zScore: -2.2),
                BrainPETRegionStatistic(labelID: 2,
                                        name: "Temporal cortex",
                                        voxelCount: 10,
                                        meanActivity: 0.9,
                                        suvr: 0.9,
                                        normalMeanSUVR: 1,
                                        normalSDSUVR: 0.1,
                                        zScore: -1.0)
            ],
            warnings: []
        )
        let challenge = BrainPETReport(
            tracer: .spectHMPAO,
            family: .spectPerfusion,
            referenceRegionName: "Whole brain",
            referenceMean: 1,
            targetSUVR: 0.88,
            centiloid: nil,
            centiloidCalibrationName: nil,
            tauGrade: nil,
            regions: [
                BrainPETRegionStatistic(labelID: 1,
                                        name: "Frontal cortex",
                                        voxelCount: 10,
                                        meanActivity: 0.84,
                                        suvr: 0.84,
                                        normalMeanSUVR: 1,
                                        normalSDSUVR: 0.1,
                                        zScore: -1.6),
                BrainPETRegionStatistic(labelID: 2,
                                        name: "Temporal cortex",
                                        voxelCount: 10,
                                        meanActivity: 1.1,
                                        suvr: 1.1,
                                        normalMeanSUVR: 1,
                                        normalSDSUVR: 0.1,
                                        zScore: 0.1)
            ],
            warnings: []
        )

        let assessment = NeuroPerfusionInterpreter.assess(report: baseline, clusters: [])
        let cvr = NeuroCVRChallengeComparison.compare(baseline: baseline, challenge: challenge)

        XCTAssertTrue(assessment.globalSummary.contains("ACA"))
        XCTAssertTrue(assessment.territorySummaries.contains { $0.territory == .anteriorCerebral && $0.abnormalRegionCount == 1 })
        XCTAssertTrue(cvr.summary.contains("ACA"))
        XCTAssertTrue(cvr.deltas.contains { $0.territory == .anteriorCerebral && $0.abnormal })
    }

    func testReferencePackStoreRoundTripsManifests() throws {
        let suiteName = "Tracer.NeuroReferencePackStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NeuroReferencePackStore(defaults: defaults, key: "packs")
        let manifest = try XCTUnwrap(NeuroReferencePackManager.manifest(for: .tauBraak))

        store.upsert(manifest)

        XCTAssertEqual(store.load().first?.id, manifest.id)
        XCTAssertTrue(NeuroReferencePackManager.compatibilityLines(
            manifest: manifest,
            atlasValidation: NeuroQuantAtlasRegistry.bestValidation(for: makeCompleteCentiloidAtlas(), workflow: .amyloidCentiloid),
            normalDatabase: nil
        ).contains { $0.contains("Validation") })
        XCTAssertTrue(store.remove(id: manifest.id).isEmpty)
    }

    func testTimelineBuilderSortsEventsAndSummarizesLatestChange() throws {
        let older = NeuroTimelineEvent(
            date: Date(timeIntervalSince1970: 10),
            studyUID: "prior",
            workflow: .amyloidCentiloid,
            targetSUVR: 1.1,
            centiloid: 5
        )
        let newer = NeuroTimelineEvent(
            date: Date(timeIntervalSince1970: 20),
            studyUID: "current",
            workflow: .amyloidCentiloid,
            targetSUVR: 1.3,
            centiloid: 30
        )

        let timeline = NeuroTimelineBuilder.build(events: [newer, older])

        XCTAssertEqual(timeline.events.map(\.studyUID), ["prior", "current"])
        XCTAssertEqual(timeline.latestChange, "Centiloid +25.0")
        XCTAssertTrue(timeline.trendSummary.contains("+25.0"))
    }

    func testDementiaBiomarkerBoardCombinesATNMarkers() {
        let report = BrainPETReport(
            tracer: .amyloidFlorbetapir,
            family: .amyloid,
            referenceRegionName: "Whole cerebellum",
            referenceMean: 1,
            targetSUVR: 1.35,
            centiloid: 65,
            centiloidCalibrationName: "test",
            tauGrade: nil,
            regions: [],
            warnings: []
        )
        let patterns = [
            NeuroDiseasePatternFinding(
                kind: .amyloidPositive,
                confidence: 0.9,
                summary: "Amyloid positive.",
                supportingRegions: [],
                cautions: []
            ),
            NeuroDiseasePatternFinding(
                kind: .tauBraakAdvanced,
                confidence: 0.8,
                summary: "Advanced tau.",
                supportingRegions: [],
                cautions: []
            ),
            NeuroDiseasePatternFinding(
                kind: .alzheimerLike,
                confidence: 0.8,
                summary: "Neurodegeneration.",
                supportingRegions: [],
                cautions: []
            )
        ]

        let board = NeuroDementiaBiomarkerBoard.make(
            report: report,
            workflow: .amyloidCentiloid,
            patterns: patterns,
            mriAssessment: nil
        )

        XCTAssertEqual(board.phenotype, "A+ T+ N+")
        XCTAssertEqual(board.amyloid, .positive)
        XCTAssertEqual(board.tau, .positive)
        XCTAssertEqual(board.neurodegeneration, .positive)
        XCTAssertTrue(board.summary.contains("Alzheimer"))
    }

    func testAntiAmyloidTherapyWorkflowHoldsForARIAAndHighRiskMRI() {
        let mri = NeuroMRIContextAnalyzer.assess(
            input: NeuroMRIContextInput(
                hasT1: true,
                microhemorrhageCount: 12,
                superficialSiderosis: true,
                ariaE: true
            ),
            workflow: .amyloidCentiloid,
            patterns: []
        )
        let context = NeuroAntiAmyloidTherapyContext(
            candidateForTherapy: true,
            agent: .lecanemab,
            apoEStatus: .homozygousE4,
            antithromboticStatus: .anticoagulant,
            symptomaticARIA: true,
            amyloidConfirmedOverride: true
        )

        let assessment = NeuroAntiAmyloidTherapyAssessment.assess(
            context: context,
            biomarkerBoard: nil,
            mriAssessment: mri,
            aucDecision: nil
        )

        XCTAssertEqual(assessment.action, .holdTherapy)
        XCTAssertEqual(assessment.riskLevel, .high)
        XCTAssertTrue(assessment.blockers.contains { $0.contains("ARIA") })
        XCTAssertTrue(assessment.monitoringSchedule.contains { $0.contains("5th") })
    }

    func testVisualReadAssistFlagsDiscordantQuantitativePattern() {
        let report = BrainPETReport(
            tracer: .fdg,
            family: .fdg,
            referenceRegionName: "Pons",
            referenceMean: 1,
            targetSUVR: 0.7,
            centiloid: nil,
            centiloidCalibrationName: nil,
            tauGrade: nil,
            regions: [
                BrainPETRegionStatistic(labelID: 1,
                                        name: "Precuneus",
                                        voxelCount: 4,
                                        meanActivity: 0.7,
                                        suvr: 0.7,
                                        normalMeanSUVR: 1,
                                        normalSDSUVR: 0.1,
                                        zScore: -3)
            ],
            warnings: []
        )
        let patterns = [
            NeuroDiseasePatternFinding(
                kind: .alzheimerLike,
                confidence: 0.8,
                summary: "AD-like.",
                supportingRegions: ["Precuneus"],
                cautions: []
            )
        ]

        let assist = NeuroVisualReadAssist.make(
            workflow: .fdgDementia,
            report: report,
            patterns: patterns,
            visualRead: NeuroVisualReadInput(impression: .normal, confidence: 0.9)
        )

        XCTAssertEqual(assist.concordance, .discordant)
        XCTAssertTrue(assist.warnings.contains { $0.contains("discordant") })
        XCTAssertEqual(assist.templateName, "FDG dementia visual template")
    }

    func testNormalGovernanceBlocksTracerMismatchAndFailedPhantom() {
        let normals = BrainPETNormalDatabase(
            id: "wrong",
            name: "Wrong tracer normals",
            tracer: .fdg,
            referenceRegion: "Pons",
            sourceDescription: "test",
            entries: [
                .init(regionName: "Striatum", meanSUVR: 4.0, sdSUVR: 0.3, sampleSize: 10, ageMin: 60, ageMax: 80)
            ]
        )
        let governance = NeuroNormalDatabaseGovernanceEvaluator.evaluate(
            workflow: .datscanStriatal,
            normalDatabase: normals,
            referenceManifest: NeuroReferencePackManager.manifest(for: .datscanStriatal),
            acquisitionSignature: NeuroAcquisitionSignature(tracer: .spectDaTscan, reconstructionDescription: "OSEM"),
            patientAge: 55,
            phantomRecords: [
                NeuroPhantomCalibrationRecord(workflow: .datscanStriatal,
                                              scannerModel: "SPECT",
                                              recoveryCoefficient: 1.3,
                                              uniformityPercent: 12)
            ]
        )

        XCTAssertEqual(governance.status, .mismatch)
        XCTAssertTrue(governance.blockers.contains { $0.contains("tracer") })
        XCTAssertTrue(governance.blockers.contains { $0.contains("phantom") })
        XCTAssertTrue(governance.warnings.contains { $0.contains("age") })
    }

    func testDaTscanMovementContextAddsMedicationWarningAndAgePercentile() throws {
        let volume = ImageVolume(
            pixels: [4, 4, 2, 2, 1],
            depth: 1,
            height: 1,
            width: 5,
            modality: "NM",
            seriesDescription: "DaTscan SPECT"
        )
        let atlas = LabelMap(
            parentSeriesUID: volume.seriesUID,
            depth: 1,
            height: 1,
            width: 5,
            name: "DaTscan striatal atlas",
            classes: [
                LabelClass(labelID: 1, name: "Left caudate", category: .brain, color: .orange),
                LabelClass(labelID: 2, name: "Right caudate", category: .brain, color: .orange),
                LabelClass(labelID: 3, name: "Left putamen", category: .brain, color: .blue),
                LabelClass(labelID: 4, name: "Right putamen", category: .brain, color: .blue),
                LabelClass(labelID: 5, name: "Occipital background", category: .brain, color: .green)
            ]
        )
        atlas.voxels = [1, 2, 3, 4, 5]
        let normals = BrainPETNormalDatabase(
            id: "dat-normal",
            name: "DaT normals",
            tracer: .spectDaTscan,
            referenceRegion: "Occipital",
            sourceDescription: "test",
            entries: [
                .init(regionName: "Striatum", meanSUVR: 3.5, sdSUVR: 0.5, sampleSize: 40, ageMin: 50, ageMax: 90)
            ]
        )

        let result = try NeuroQuantWorkbench.run(
            volume: volume,
            atlas: atlas,
            normalDatabase: normals,
            workflow: .datscanStriatal,
            anatomyVolume: nil,
            anatomyMode: .petOnly,
            movementDisorderContext: NeuroMovementDisorderContext(
                age: 70,
                medications: [.bupropion],
                visualGrade: .abnormalMild
            )
        )

        XCTAssertEqual(result.datscanAssessment?.visualGrade, .abnormalMild)
        XCTAssertNotNil(result.datscanAssessment?.ageMatchedPercentile)
        XCTAssertTrue(result.datscanAssessment?.medicationWarnings.contains { $0.contains("Bupropion") } == true)
        XCTAssertTrue(result.datscanAssessment?.limitationLines.contains { $0.contains("does not by itself distinguish") } == true)
    }

    func testSeizurePerfusionComparisonRanksIctalFocus() {
        let interictal = BrainPETReport(
            tracer: .spectHMPAO,
            family: .spectPerfusion,
            referenceRegionName: "Whole brain",
            referenceMean: 1,
            targetSUVR: nil,
            centiloid: nil,
            centiloidCalibrationName: nil,
            tauGrade: nil,
            regions: [
                BrainPETRegionStatistic(labelID: 1, name: "Left temporal cortex", voxelCount: 10, meanActivity: 1, suvr: 1, normalMeanSUVR: 1, normalSDSUVR: 0.2, zScore: 0),
                BrainPETRegionStatistic(labelID: 2, name: "Right frontal cortex", voxelCount: 10, meanActivity: 1, suvr: 1, normalMeanSUVR: 1, normalSDSUVR: 0.2, zScore: 0)
            ],
            warnings: []
        )
        let ictal = BrainPETReport(
            tracer: .spectHMPAO,
            family: .spectPerfusion,
            referenceRegionName: "Whole brain",
            referenceMean: 1,
            targetSUVR: nil,
            centiloid: nil,
            centiloidCalibrationName: nil,
            tauGrade: nil,
            regions: [
                BrainPETRegionStatistic(labelID: 1, name: "Left temporal cortex", voxelCount: 10, meanActivity: 1.6, suvr: 1.6, normalMeanSUVR: 1, normalSDSUVR: 0.2, zScore: 3),
                BrainPETRegionStatistic(labelID: 2, name: "Right frontal cortex", voxelCount: 10, meanActivity: 1.1, suvr: 1.1, normalMeanSUVR: 1, normalSDSUVR: 0.2, zScore: 0.4)
            ],
            warnings: []
        )

        let comparison = NeuroSeizurePerfusionComparison.compare(interictal: interictal, ictal: ictal)

        XCTAssertEqual(comparison.candidates.first?.regionName, "Left temporal cortex")
        XCTAssertTrue(comparison.summary.contains("Left temporal"))
        XCTAssertTrue(comparison.reportLines.first?.contains("Top seizure") == true)
    }

    func testClinicalQAAndAuditStoreRequireSignoffThenRecordAudit() throws {
        let readiness = NeuroQuantClinicalReadiness(
            status: .locallyValidated,
            evidenceLevel: .localValidation,
            blockers: [],
            warnings: [],
            evidenceLines: []
        )

        let unsigned = NeuroClinicalQAResult.evaluate(
            readiness: readiness,
            aucDecision: nil,
            visualReadAssist: nil,
            normalGovernance: nil,
            antiAmyloidAssessment: nil,
            signoff: nil
        )
        let signed = NeuroClinicalQAResult.evaluate(
            readiness: readiness,
            aucDecision: nil,
            visualReadAssist: nil,
            normalGovernance: nil,
            antiAmyloidAssessment: nil,
            signoff: NeuroClinicalSignoff(
                readerName: "Reader",
                attestation: "Reviewed",
                thresholdOverrides: ["Tau threshold 1.34"],
                correctedRegions: ["Left temporal"]
            )
        )
        let suiteName = "Tracer.NeuroAuditTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NeuroClinicalAuditStore(defaults: defaults, key: "audit")
        store.append(signed.auditEvents)

        XCTAssertEqual(unsigned.status, .warning)
        XCTAssertEqual(signed.status, .signed)
        XCTAssertEqual(store.load().count, 3)
        XCTAssertTrue(store.load().contains { $0.kind == "threshold" })
    }

    func testValidationCSVParserImportsSiteCases() {
        let text = """
        id,expected,observed
        a,10,11
        b,20,19.5
        """

        let cases = NeuroValidationCaseCSVParser.parse(text)

        XCTAssertEqual(cases.count, 2)
        XCTAssertEqual(cases.first?.id, "a")
        XCTAssertEqual(cases.last?.observedValue, 19.5)
    }

    func testWorkbenchReportIncludesNextLayerSections() throws {
        let atlas = makeCompleteCentiloidAtlas()
        let volume = ImageVolume(
            pixels: [1.4, 1.4, 1.4, 1.4, 1.4, 1.4, 1.0],
            depth: 1,
            height: 1,
            width: 7,
            modality: "PT",
            seriesDescription: "Amyloid therapy PET"
        )
        let result = try NeuroQuantWorkbench.run(
            volume: volume,
            atlas: atlas,
            normalDatabase: nil,
            workflow: .amyloidCentiloid,
            anatomyVolume: nil,
            anatomyMode: .petOnly,
            clinicalIntake: NeuroAUCIntake(
                questions: [.mildCognitiveImpairment, .antiAmyloidTherapyEligibility],
                treatmentEligibilityQuestion: true,
                hasRecentMRI: true
            ),
            mriContext: NeuroMRIContextInput(hasT1: true),
            antiAmyloidContext: NeuroAntiAmyloidTherapyContext(candidateForTherapy: true, amyloidConfirmedOverride: true),
            visualRead: NeuroVisualReadInput(impression: .abnormalHighBinding, confidence: 0.9),
            timelineEvents: [
                NeuroTimelineEvent(
                    date: Date(timeIntervalSince1970: 1),
                    studyUID: "prior",
                    workflow: .amyloidCentiloid,
                    targetSUVR: 1.1,
                    centiloid: 10
                )
            ],
            signoff: NeuroClinicalSignoff(readerName: "Reader", attestation: "Reviewed")
        )

        XCTAssertNotNil(result.biomarkerBoard)
        XCTAssertNotNil(result.antiAmyloidAssessment)
        XCTAssertNotNil(result.visualReadAssist)
        XCTAssertNotNil(result.normalGovernance)
        XCTAssertNotNil(result.longitudinalTimeline)
        XCTAssertNotNil(result.clinicalQA)
        XCTAssertNotNil(result.antiAmyloidClinicTracker)
        XCTAssertFalse(result.dicomAuditTrail.entries.isEmpty)
        XCTAssertTrue(result.structuredReport.plainText.contains("AT(N) Board"))
        XCTAssertTrue(result.structuredReport.plainText.contains("Anti-Amyloid Therapy"))
        XCTAssertTrue(result.structuredReport.plainText.contains("Registration Pipeline"))
        XCTAssertTrue(result.structuredReport.plainText.contains("Validation Workbench"))
        XCTAssertTrue(result.structuredReport.plainText.contains("Comparison Workspace"))
        XCTAssertTrue(result.structuredReport.plainText.contains("AI Classifier Hook"))
        XCTAssertTrue(result.structuredReport.plainText.contains("DICOM Audit Trail"))
        XCTAssertTrue(result.structuredReport.plainText.contains("Clinical QA"))
    }

    func testNeuroRegistrationPipelineUsesExistingPETMRAndQA() {
        let pet = makeBlobVolume(modality: "PT", description: "FDG PET")
        let mr = makeBlobVolume(modality: "MR", description: "T1 MRI")
        let atlas = makeCompleteCentiloidAtlas()
        let validation = NeuroQuantAtlasRegistry.bestValidation(for: atlas, workflow: .amyloidCentiloid)

        let pipeline = NeuroRegistrationPipeline.plan(
            volume: pet,
            anatomyVolume: mr,
            atlasValidation: validation,
            workflow: .amyloidCentiloid
        )

        XCTAssertEqual(pipeline.registrationMode, .brainMRIDriven)
        XCTAssertNotNil(pipeline.beforeQA)
        XCTAssertNotNil(pipeline.afterQA)
        XCTAssertTrue(pipeline.stages.contains { $0.kind == .rigid })
        XCTAssertTrue(pipeline.stages.contains { $0.kind == .qualityControl })
        XCTAssertTrue(pipeline.reportLines.contains { $0.contains("Mode: Brain MRI-driven") })
    }

    func testDICOMManifestTextSRAndZScoreVolumeAreExportable() throws {
        let atlas = makeCompleteCentiloidAtlas()
        let volume = ImageVolume(
            pixels: [1.4, 1.4, 1.4, 1.4, 1.4, 1.4, 1.0],
            depth: 1,
            height: 1,
            width: 7,
            modality: "PT",
            patientID: "P1",
            patientName: "Test^Patient",
            seriesDescription: "Amyloid PET"
        )
        let result = try NeuroQuantWorkbench.run(
            volume: volume,
            atlas: atlas,
            normalDatabase: nil,
            workflow: .amyloidCentiloid,
            anatomyVolume: nil,
            anatomyMode: .petOnly
        )

        let manifest = result.dicomExportManifest
        XCTAssertTrue(manifest.objectTypes.contains { $0.contains("DICOM Basic Text SR") })
        XCTAssertTrue(manifest.parametricMaps.contains { $0.kind == .zScore })
        XCTAssertTrue(manifest.parametricMaps.contains { $0.kind == .centiloid })

        let payload = NeuroDICOMSRExporter.makeTextSRPayload(
            report: result.structuredReport,
            manifest: manifest,
            sourceVolume: volume
        )
        XCTAssertGreaterThan(payload.count, 132)
        XCTAssertEqual(String(data: payload.subdata(in: 128..<132), encoding: .ascii), "DICM")

        let zVolume = NeuroParametricMapExporter.makeZScoreVolume(
            from: result.zScoreMap,
            source: volume,
            workflow: .amyloidCentiloid
        )
        XCTAssertEqual(zVolume.modality, "OT")
        XCTAssertEqual(zVolume.pixels, result.zScoreMap.values)
        XCTAssertTrue(zVolume.seriesDescription.contains("z-score"))
    }

    func testValidationDashboardAndComparisonWorkspaceAreIncluded() throws {
        let atlas = makeCompleteCentiloidAtlas()
        let validationCases = (0..<20).map {
            NeuroQuantValidationCase(id: "case-\($0)", expectedValue: Double($0), observedValue: Double($0) + 0.5)
        }
        let validation = NeuroQuantClinicalValidationResult.evaluate(
            workflow: .amyloidCentiloid,
            metric: .centiloid,
            cases: validationCases,
            sourceDescription: "Site validation"
        )
        let result = try NeuroQuantWorkbench.run(
            volume: ImageVolume(pixels: [1.4, 1.4, 1.4, 1.4, 1.4, 1.4, 1.0], depth: 1, height: 1, width: 7, modality: "PT"),
            atlas: atlas,
            normalDatabase: nil,
            workflow: .amyloidCentiloid,
            anatomyVolume: nil,
            anatomyMode: .petOnly,
            localValidation: validation
        )

        XCTAssertEqual(result.validationDashboard.metric, .centiloid)
        XCTAssertTrue(result.validationDashboard.regressionLine?.contains("R2") == true)
        XCTAssertTrue(result.validationDashboard.lockRecommendation.contains("locally validated"))
        XCTAssertTrue(result.comparisonWorkspace.panes.contains { $0.kind == .zScoreMap })
        XCTAssertTrue(result.comparisonWorkspace.panes.contains { $0.kind == .structuredReport })
        XCTAssertTrue(result.structuredReport.plainText.contains("Validation Workbench"))
        XCTAssertTrue(result.structuredReport.plainText.contains("Comparison Workspace"))
    }

    func testTherapyTrackerAIClassifierAndDICOMAuditAreDistinctOutputs() throws {
        let atlas = makeCompleteCentiloidAtlas()
        let result = try NeuroQuantWorkbench.run(
            volume: ImageVolume(pixels: [1.4, 1.4, 1.4, 1.4, 1.4, 1.4, 1.0], depth: 1, height: 1, width: 7, modality: "PT"),
            atlas: atlas,
            normalDatabase: nil,
            workflow: .amyloidCentiloid,
            anatomyVolume: nil,
            anatomyMode: .petOnly,
            clinicalIntake: NeuroAUCIntake(
                questions: [.mildCognitiveImpairment, .antiAmyloidTherapyEligibility],
                treatmentEligibilityQuestion: true,
                hasRecentMRI: true
            ),
            mriContext: NeuroMRIContextInput(hasT1: true),
            antiAmyloidContext: NeuroAntiAmyloidTherapyContext(
                candidateForTherapy: true,
                agent: .lecanemab,
                infusionNumber: 4,
                amyloidConfirmedOverride: true
            ),
            visualRead: NeuroVisualReadInput(impression: .abnormalHighBinding, confidence: 0.9),
            timelineEvents: [
                NeuroTimelineEvent(
                    date: Date(timeIntervalSince1970: 1),
                    studyUID: "baseline",
                    workflow: .amyloidCentiloid,
                    targetSUVR: 1.1,
                    centiloid: 8
                )
            ],
            signoff: NeuroClinicalSignoff(readerName: "Reader", attestation: "Reviewed")
        )

        let tracker = try XCTUnwrap(result.antiAmyloidClinicTracker)
        XCTAssertTrue(tracker.nextMRIDescription.contains("infusion 5"))
        XCTAssertTrue(tracker.milestones.contains { $0.id == "mri-5" })
        XCTAssertEqual(result.aiClassifierPrediction.request.modelIdentifier, "tracer-neuro-heuristic-v1")
        XCTAssertGreaterThan(result.aiClassifierPrediction.confidence, 0.5)
        XCTAssertTrue(result.dicomAuditTrail.entries.contains { $0.kind == "dicom-sr" })
        XCTAssertTrue(result.dicomAuditTrail.entries.contains { $0.kind == "parametric-map" })
        XCTAssertEqual(result.dicomAuditTrail.signedBy, "Reader")
    }

    private func makeCentiloidAtlas() -> LabelMap {
        let atlas = LabelMap(
            parentSeriesUID: "amyloid",
            depth: 1,
            height: 1,
            width: 3,
            name: "Clark Centiloid atlas",
            classes: [
                LabelClass(labelID: 1, name: "Frontal cortex", category: .brain, color: .orange),
                LabelClass(labelID: 2, name: "Precuneus cortex", category: .brain, color: .blue),
                LabelClass(labelID: 3, name: "Whole cerebellum", category: .brain, color: .green)
            ]
        )
        atlas.voxels = [1, 2, 3]
        return atlas
    }

    private func makeCompleteCentiloidAtlas() -> LabelMap {
        let atlas = LabelMap(
            parentSeriesUID: "amyloid-complete",
            depth: 1,
            height: 1,
            width: 7,
            name: "Complete Clark Centiloid atlas",
            classes: [
                LabelClass(labelID: 1, name: "Frontal cortex", category: .brain, color: .orange),
                LabelClass(labelID: 2, name: "Temporal cortex", category: .brain, color: .blue),
                LabelClass(labelID: 3, name: "Anterior cingulate cortex", category: .brain, color: .purple),
                LabelClass(labelID: 4, name: "Posterior cingulate cortex", category: .brain, color: .pink),
                LabelClass(labelID: 5, name: "Parietal cortex", category: .brain, color: .cyan),
                LabelClass(labelID: 6, name: "Precuneus cortex", category: .brain, color: .red),
                LabelClass(labelID: 7, name: "Whole cerebellum", category: .brain, color: .green)
            ]
        )
        atlas.voxels = [1, 2, 3, 4, 5, 6, 7]
        return atlas
    }

    private func makeBlobVolume(modality: String, description: String) -> ImageVolume {
        let width = 8
        let height = 8
        let depth = 8
        var pixels: [Float] = []
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let dx = Double(x) - 3.5
                    let dy = Double(y) - 3.5
                    let dz = Double(z) - 3.5
                    let signal = exp(-(dx * dx + dy * dy + dz * dz) / 12.0)
                    pixels.append(Float(signal * 100.0 + Double(x + y + z) * 0.25))
                }
            }
        }
        return ImageVolume(
            pixels: pixels,
            depth: depth,
            height: height,
            width: width,
            spacing: (2, 2, 2),
            modality: modality,
            seriesDescription: description
        )
    }
}
