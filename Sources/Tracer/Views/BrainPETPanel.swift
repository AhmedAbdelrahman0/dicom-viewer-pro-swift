import SwiftUI
import UniformTypeIdentifiers

struct BrainPETPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var workflow: NeuroQuantWorkflowProtocol = .fdgDementia
    @State private var anatomyMode: BrainPETAnatomyMode = .automatic
    @State private var tauThreshold: Double = 1.34
    @State private var clinicalQuestion: NeuroClinicalQuestion = .cognitiveDecline
    @State private var includeAtypicalDementia = false
    @State private var includeEarlyOnset = false
    @State private var antiAmyloidEligibility = false
    @State private var hasRecentMRI = false
    @State private var hippocampalAtrophy = false
    @State private var vascularBurden: NeuroVascularBurden = .none
    @State private var microhemorrhageCount = 0
    @State private var antiAmyloidAgent: NeuroAntiAmyloidAgent = .lecanemab
    @State private var apoEStatus: NeuroApoEStatus = .unknown
    @State private var antithromboticStatus: NeuroAntithromboticStatus = .none
    @State private var visualReadImpression: NeuroVisualReadImpression = .notAssessed
    @State private var datscanVisualGrade: NeuroDaTscanVisualGrade = .notAssessed
    @State private var datscanMedicationFlag = false
    @State private var includePriorStudy = false
    @State private var priorTargetSUVR = 1.0
    @State private var priorCentiloid = 0.0
    @State private var priorYearsAgo = 1.0
    @State private var readerName = ""
    @State private var showNormalDatabaseImporter = false
    @State private var gaainSummary: GAAINReferenceDatasetSummary?
    @State private var gaainPackage: GAAINReferenceBuildPackage?
    @State private var gaainStatus: String = ""
    @State private var isGAAINRemoteRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            if let anatomyReport = vm.brainPETAnatomyAwareReport {
                anatomyAwareSummaryView(anatomyReport)
                reportView(anatomyReport.anatomyAwareReport)
            } else if let report = vm.brainPETReport {
                reportView(report)
            } else {
                emptyState
            }
            if let result = vm.neuroQuantWorkbenchResult {
                neuroWorkbenchView(result)
            }
            gaainReferenceBuilder
            normalSources
        }
    }

    private var header: some View {
        HStack {
            Label("Neuro Quant", systemImage: "brain.head.profile")
                .font(.headline)
            Spacer()
            if let pet = vm.activePETQuantificationVolume {
                Text(pet.seriesDescription.isEmpty ? "PET" : pet.seriesDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Protocol", selection: $workflow) {
                ForEach(NeuroQuantWorkflowProtocol.allCases) { protocolID in
                    Text(protocolID.displayName).tag(protocolID)
                }
            }

            Text(workflow.lockedSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            metric("Tracer", workflow.tracer.displayName)
            metric("Template", workflow.preferredTemplateSpace.displayName)

            clinicalIntakeControls
            clinicalWorkflowControls

            Picker("Anatomy", selection: $anatomyMode) {
                ForEach(BrainPETAnatomyMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            }

            if let anatomy = vm.activeBrainPETAnatomyVolume(for: anatomyMode) {
                Label(anatomy.seriesDescription.isEmpty ? Modality.normalize(anatomy.modality).displayName : anatomy.seriesDescription,
                      systemImage: anatomyMode.systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if anatomyMode != .petOnly {
                Label("No matching CT/MRI anatomy found; PET-only fallback will be used.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if workflow == .tauBraak {
                HStack {
                    Text("Tau threshold")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", tauThreshold))
                        .font(.caption.monospaced())
                }
                Slider(value: $tauThreshold, in: 1.05...2.2, step: 0.01)
            }

            if vm.labeling.activeLabelMap == nil {
                Button {
                    _ = vm.createQuickBrainPETAtlasForActivePET()
                } label: {
                    Label("Create Quick PET Atlas", systemImage: "map")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.activePETQuantificationVolume == nil)
                .help("Creates a coarse PET-derived research atlas so Analyze can run. Replace it with a registered anatomical atlas for clinical-grade regional analysis.")
            }

            Button {
                _ = vm.runActiveNeuroQuantification(workflow: workflow,
                                                    anatomyMode: anatomyMode,
                                                    tauSUVRThreshold: workflow == .tauBraak ? tauThreshold : nil,
                                                    clinicalIntake: makeClinicalIntake(),
                                                    mriContext: makeMRIContext(),
                                                    antiAmyloidContext: makeAntiAmyloidContext(),
                                                    visualRead: makeVisualReadInput(),
                                                    movementDisorderContext: makeMovementDisorderContext(),
                                                    timelineEvents: makeTimelineEvents(),
                                                    signoff: makeSignoff())
            } label: {
                Label("Run Protocol", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(vm.activePETQuantificationVolume == nil)
            .help(vm.labeling.activeLabelMap == nil
                  ? "Analyze will create a coarse PET-derived quick atlas if no PET-aligned brain atlas is loaded."
                  : "Run the locked neuroquantification protocol.")

            HStack(spacing: 8) {
                Button {
                    showNormalDatabaseImporter = true
                } label: {
                    Label("Import Norms", systemImage: "tablecells")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    vm.clearBrainPETNormalDatabase()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.brainPETNormalDatabase == nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let database = vm.brainPETNormalDatabase {
                Label(database.name, systemImage: "externaldrive.badge.checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .fileImporter(isPresented: $showNormalDatabaseImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result,
               let url = urls.first {
                vm.importBrainPETNormalDatabase(from: url, tracer: workflow.tracer)
            }
        }
    }

    private var clinicalIntakeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Question", selection: $clinicalQuestion) {
                ForEach(NeuroClinicalQuestion.allCases) { question in
                    Text(question.displayName).tag(question)
                }
            }

            Toggle("Atypical", isOn: $includeAtypicalDementia)
                .toggleStyle(.checkbox)
            Toggle("Early onset", isOn: $includeEarlyOnset)
                .toggleStyle(.checkbox)
            Toggle("Therapy eligibility", isOn: $antiAmyloidEligibility)
                .toggleStyle(.checkbox)

            Divider()

            Toggle("Recent MRI", isOn: $hasRecentMRI)
                .toggleStyle(.checkbox)
            Toggle("Hippocampal atrophy", isOn: $hippocampalAtrophy)
                .toggleStyle(.checkbox)
            Picker("Vascular", selection: $vascularBurden) {
                ForEach(NeuroVascularBurden.allCases) { burden in
                    Text(burden.displayName).tag(burden)
                }
            }
            Stepper("Microhemorrhages \(microhemorrhageCount)", value: $microhemorrhageCount, in: 0...50)
        }
        .font(.caption)
    }

    private var clinicalWorkflowControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Visual", selection: $visualReadImpression) {
                ForEach(NeuroVisualReadImpression.allCases) { impression in
                    Text(impression.displayName).tag(impression)
                }
            }

            if antiAmyloidEligibility {
                Picker("Agent", selection: $antiAmyloidAgent) {
                    ForEach(NeuroAntiAmyloidAgent.allCases) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
                Picker("ApoE", selection: $apoEStatus) {
                    ForEach(NeuroApoEStatus.allCases) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                Picker("Blood thinner", selection: $antithromboticStatus) {
                    ForEach(NeuroAntithromboticStatus.allCases) { status in
                        Text(status.displayName).tag(status)
                    }
                }
            }

            if workflow == .datscanStriatal {
                Picker("DaT visual", selection: $datscanVisualGrade) {
                    ForEach(NeuroDaTscanVisualGrade.allCases) { grade in
                        Text(grade.displayName).tag(grade)
                    }
                }
                Toggle("DAT-interfering med", isOn: $datscanMedicationFlag)
                    .toggleStyle(.checkbox)
            }

            Toggle("Prior study", isOn: $includePriorStudy)
                .toggleStyle(.checkbox)
            if includePriorStudy {
                Stepper("Prior years \(String(format: "%.1f", priorYearsAgo))", value: $priorYearsAgo, in: 0.25...10, step: 0.25)
                Stepper("Prior SUVR \(String(format: "%.2f", priorTargetSUVR))", value: $priorTargetSUVR, in: 0...5, step: 0.05)
                if workflow == .amyloidCentiloid {
                    Stepper("Prior CL \(String(format: "%.0f", priorCentiloid))", value: $priorCentiloid, in: -50...200, step: 1)
                }
            }

            TextField("Reader", text: $readerName)
                .textFieldStyle(.roundedBorder)
        }
        .font(.caption)
    }

    private func makeClinicalIntake() -> NeuroAUCIntake {
        var questions = [clinicalQuestion]
        if includeAtypicalDementia { questions.append(.atypicalDementia) }
        if includeEarlyOnset { questions.append(.earlyOnsetDementia) }
        if antiAmyloidEligibility { questions.append(.antiAmyloidTherapyEligibility) }
        let uniqueQuestions = Array(Set(questions)).sorted { $0.rawValue < $1.rawValue }
        return NeuroAUCIntake(
            questions: uniqueQuestions,
            treatmentEligibilityQuestion: antiAmyloidEligibility,
            hasRecentMRI: hasRecentMRI
        )
    }

    private func makeMRIContext() -> NeuroMRIContextInput? {
        guard hasRecentMRI ||
                hippocampalAtrophy ||
                vascularBurden != .none ||
                microhemorrhageCount > 0 else {
            return nil
        }
        return NeuroMRIContextInput(
            hasT1: hasRecentMRI,
            hippocampalAtrophy: hippocampalAtrophy,
            microhemorrhageCount: microhemorrhageCount,
            vascularBurden: vascularBurden
        )
    }

    private func makeAntiAmyloidContext() -> NeuroAntiAmyloidTherapyContext? {
        guard antiAmyloidEligibility else { return nil }
        return NeuroAntiAmyloidTherapyContext(
            candidateForTherapy: true,
            agent: antiAmyloidAgent,
            apoEStatus: apoEStatus,
            antithromboticStatus: antithromboticStatus
        )
    }

    private func makeVisualReadInput() -> NeuroVisualReadInput {
        NeuroVisualReadInput(
            impression: visualReadImpression,
            confidence: visualReadImpression == .notAssessed ? 0 : 0.8
        )
    }

    private func makeMovementDisorderContext() -> NeuroMovementDisorderContext? {
        guard workflow == .datscanStriatal else { return nil }
        return NeuroMovementDisorderContext(
            medications: datscanMedicationFlag ? [.bupropion] : [],
            visualGrade: datscanVisualGrade,
            clinicalQuestion: clinicalQuestion == .essentialTremorQuestion ? .essentialTremorQuestion : .parkinsonism
        )
    }

    private func makeTimelineEvents() -> [NeuroTimelineEvent] {
        guard includePriorStudy else { return [] }
        let priorDate = Date().addingTimeInterval(-priorYearsAgo * 365.25 * 24 * 60 * 60)
        return [
            NeuroTimelineEvent(
                date: priorDate,
                studyUID: "prior-neuroquant",
                workflow: workflow,
                targetSUVR: priorTargetSUVR,
                centiloid: workflow == .amyloidCentiloid ? priorCentiloid : nil
            )
        ]
    }

    private func makeSignoff() -> NeuroClinicalSignoff? {
        let trimmed = readerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NeuroClinicalSignoff(
            readerName: trimmed,
            attestation: "Reader reviewed quantitative output, visual read, reference compatibility, and clinical warnings."
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Atlas required", systemImage: "map")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Use a PET/SPECT-aligned brain atlas label map for regional SUVR, Centiloid, SBR, z-score maps, clusters, and surface projections.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TracerTheme.viewportBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func anatomyAwareSummaryView(_ report: BrainPETAnatomyAwareReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(report.resolvedMode.displayName, systemImage: report.resolvedMode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(report.confidence.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(confidenceColor(report.confidence))
            }
            if let anatomy = report.anatomySeriesDescription,
               !anatomy.isEmpty {
                metric("Anatomy", anatomy)
            }
            HStack(spacing: 8) {
                comparisonColumn(title: "Standard",
                                 suvr: report.standardReport.targetSUVR,
                                 centiloid: report.standardReport.centiloid)
                comparisonColumn(title: "Anatomy-aware",
                                 suvr: report.anatomyAwareReport.targetSUVR,
                                 centiloid: report.anatomyAwareReport.centiloid)
            }
            if report.delta.targetSUVR != nil || report.delta.centiloid != nil {
                HStack(spacing: 10) {
                    if let delta = report.delta.targetSUVR {
                        metricChip("ΔSUVR", String(format: "%+.3f", delta))
                    }
                    if let delta = report.delta.centiloid {
                        metricChip("ΔCL", String(format: "%+.1f", delta))
                    }
                }
            }
            VStack(spacing: 4) {
                ForEach(report.qcMetrics) { metric in
                    HStack {
                        Image(systemName: metric.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(metric.passed ? .green : .orange)
                            .frame(width: 16)
                        Text(metric.title)
                            .font(.caption2)
                        Spacer()
                        Text(metric.value)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if !report.warnings.isEmpty {
                Divider()
                ForEach(report.warnings.prefix(3), id: \.self) { warning in
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(TracerTheme.viewportBackground.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func comparisonColumn(title: String, suvr: Double?, centiloid: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(suvr.map { String(format: "SUVR %.3f", $0) } ?? "SUVR --")
                .font(.caption2.monospaced())
            if let centiloid {
                Text(String(format: "CL %.1f", centiloid))
                    .font(.caption2.monospaced())
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TracerTheme.panelBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func metricChip(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption2.monospaced())
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(TracerTheme.accent.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func reportView(_ report: BrainPETReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(report.summary, systemImage: icon(for: report.family))
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            metric("Reference", report.referenceRegionName)
            metric("Ref mean", String(format: "%.3f", report.referenceMean))
            if let target = report.targetSUVR {
                metric("Target SUVR", String(format: "%.3f", target))
            }
            if let centiloid = report.centiloid {
                metric("Centiloid", String(format: "%.1f", centiloid))
            }
            if let calibration = report.centiloidCalibrationName {
                metric("Calibration", calibration)
            }

            if let tau = report.tauGrade {
                Divider()
                metric("Tau grade", tau.stage)
                ForEach(tau.groups) { group in
                    HStack {
                        Image(systemName: group.positive ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(group.positive ? .orange : .secondary)
                            .frame(width: 16)
                        Text(group.name)
                            .font(.caption2)
                        Spacer()
                        Text(group.meanSUVR.map { String(format: "%.3f", $0) } ?? "--")
                            .font(.caption2.monospaced())
                    }
                }
            }

            Divider()
            Text("Regions")
                .font(.system(size: 11, weight: .semibold))
            ForEach(Array(report.regions.prefix(10))) { region in
                regionRow(region, family: report.family)
            }

            if !report.warnings.isEmpty {
                Divider()
                ForEach(report.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(TracerTheme.viewportBackground.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func neuroWorkbenchView(_ result: NeuroQuantWorkbenchResult) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    metric("Workflow", result.workflow.displayName)
                    metric("Atlas", "\(result.atlasValidation.pack.name) \(result.atlasValidation.pack.version)")
                    metric("Atlas score", String(format: "%.0f%%", result.atlasValidation.score * 100))
                    metric("Template", result.templatePlan.templateSpace.displayName)
                    metric("Registration", result.registrationPipeline.afterQA?.grade.displayName ?? result.registrationPipeline.templateSpace.displayName)
                    metric("Readiness", result.clinicalReadiness.status.displayName)
                    metric("Validation", result.validationDashboard.status.displayName)
                    metric("Z-map peak", String(format: "%.2f", result.zScoreMap.peakMagnitude))
                    metric("Clusters", "\(result.clusters.count)")
                    metric("DICOM objects", "\(result.dicomAuditTrail.entries.count)")
                    metric("AI hook", String(format: "%@ %.0f%%", result.aiClassifierPrediction.predictedLabel, result.aiClassifierPrediction.confidence * 100))
                    if let auc = result.aucDecision {
                        metric("AUC", auc.rating.displayName)
                    }
                    if let pattern = result.diseasePatterns.first {
                        metric("Pattern", pattern.kind.displayName)
                    }
                    if let mri = result.mriContextAssessment {
                        metric("MRI risk", mri.riskLevel.displayName)
                    }
                    if let qa = result.clinicalQA {
                        metric("QA", qa.status.displayName)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Registration Pipeline")
                        .font(.system(size: 11, weight: .semibold))
                    metric("Fixed space", result.registrationPipeline.fixedSpaceDescription)
                    if let mode = result.registrationPipeline.registrationMode {
                        metric("Mode", mode.displayName)
                    }
                    ForEach(result.registrationPipeline.reportLines.prefix(5), id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(line.contains("Warning") ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let auc = result.aucDecision {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Appropriateness")
                            .font(.system(size: 11, weight: .semibold))
                        ForEach(auc.reportLines.prefix(5), id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !result.diseasePatterns.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Disease Pattern")
                            .font(.system(size: 11, weight: .semibold))
                        ForEach(result.diseasePatterns.prefix(3)) { finding in
                            HStack {
                                Text(finding.kind.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer()
                                Text(String(format: "%.0f%%", finding.confidence * 100))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(finding.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let mri = result.mriContextAssessment {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MRI Context")
                            .font(.system(size: 11, weight: .semibold))
                        ForEach(mri.reportLines.prefix(5), id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(line.contains("Warning") ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let board = result.biomarkerBoard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AT(N)")
                            .font(.system(size: 11, weight: .semibold))
                        metric("Profile", board.phenotype)
                        Text(board.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let therapy = result.antiAmyloidAssessment {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Anti-Amyloid")
                            .font(.system(size: 11, weight: .semibold))
                        metric("Action", therapy.action.displayName)
                        metric("Risk", therapy.riskLevel.displayName)
                        ForEach((therapy.blockers + therapy.warnings).prefix(4), id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(therapy.blockers.contains(line) ? .red : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let visual = result.visualReadAssist {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Visual Read")
                            .font(.system(size: 11, weight: .semibold))
                        metric("Template", visual.templateName)
                        metric("Concordance", visual.concordance.displayName)
                        ForEach(visual.warnings.prefix(3), id: \.self) { warning in
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let governance = result.normalGovernance {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reference Governance")
                            .font(.system(size: 11, weight: .semibold))
                        metric("Status", governance.status.displayName)
                        ForEach((governance.blockers + governance.warnings).prefix(4), id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(governance.blockers.contains(line) ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !result.clinicalReadiness.blockers.isEmpty || !result.clinicalReadiness.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.clinicalReadiness.blockers, id: \.self) { blocker in
                            Label(blocker, systemImage: "xmark.octagon")
                                .foregroundStyle(.red)
                        }
                        ForEach(result.clinicalReadiness.warnings.prefix(4), id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Validation")
                        .font(.system(size: 11, weight: .semibold))
                    Text(result.validationDashboard.lockRecommendation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(result.validationDashboard.reportLines.prefix(5), id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Comparison Workspace")
                        .font(.system(size: 11, weight: .semibold))
                    metric("Layout", result.comparisonWorkspace.layoutName)
                    metric("Panes", "\(result.comparisonWorkspace.panes.count)")
                    ForEach(result.comparisonWorkspace.panes.prefix(4)) { pane in
                        HStack {
                            Text(pane.kind.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer()
                            Text(pane.linkedCrosshair ? "linked" : "free")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let metrics = result.striatalMetrics {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Striatal Binding")
                            .font(.system(size: 11, weight: .semibold))
                        if let mean = metrics.meanStriatalBindingRatio {
                            metric("Mean SBR", String(format: "%.3f", mean))
                        }
                        if let asymmetry = metrics.asymmetryPercent {
                            metric("Asymmetry", String(format: "%.1f%%", asymmetry))
                        }
                        if let ratio = metrics.putamenCaudateRatio {
                            metric("Put/Caud", String(format: "%.3f", ratio))
                        }
                        if let drop = metrics.caudatePutamenDropoffPercent {
                            metric("Drop-off", String(format: "%.1f%%", drop))
                        }
                        if let assessment = result.datscanAssessment {
                            Text(assessment.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let perfusion = result.perfusionAssessment {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Perfusion")
                            .font(.system(size: 11, weight: .semibold))
                        Text(perfusion.globalSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(perfusion.territorySummaries.prefix(4)) { summary in
                            HStack {
                                Text(summary.territory.displayName)
                                    .font(.caption2)
                                Spacer()
                                Text(summary.meanZScore.map { String(format: "z %.2f", $0) } ?? "z --")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let seizure = result.seizureComparison {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Seizure Perfusion")
                            .font(.system(size: 11, weight: .semibold))
                        Text(seizure.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let timeline = result.longitudinalTimeline {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Timeline")
                            .font(.system(size: 11, weight: .semibold))
                        Text(timeline.trendSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(timeline.slopeLines.prefix(3), id: \.self) { line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let qa = result.clinicalQA {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Clinical QA")
                            .font(.system(size: 11, weight: .semibold))
                        metric("Status", qa.status.displayName)
                        ForEach((qa.blockers + qa.warnings).prefix(5), id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(qa.blockers.contains(line) ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let tracker = result.antiAmyloidClinicTracker {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Therapy Tracker")
                            .font(.system(size: 11, weight: .semibold))
                        metric("Action", tracker.action.displayName)
                        Text(tracker.nextMRIDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(tracker.responseSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Classifier Hook")
                        .font(.system(size: 11, weight: .semibold))
                    metric("Model", result.aiClassifierPrediction.request.modelIdentifier)
                    metric("Prediction", String(format: "%@ %.0f%%", result.aiClassifierPrediction.predictedLabel, result.aiClassifierPrediction.confidence * 100))
                    ForEach(result.aiClassifierPrediction.warnings.prefix(2), id: \.self) { warning in
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("DICOM Export")
                        .font(.system(size: 11, weight: .semibold))
                    metric("SR", result.dicomExportManifest.structuredReportTitle)
                    metric("Maps", "\(result.dicomExportManifest.parametricMaps.count)")
                    ForEach(result.dicomAuditTrail.reportLines.prefix(5), id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(line.contains("Warning") ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !result.clusters.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Abnormal Clusters")
                            .font(.system(size: 11, weight: .semibold))
                        ForEach(result.clusters.prefix(5)) { cluster in
                            HStack {
                                Text(cluster.dominantRegion)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(cluster.voxelCount)")
                                    .font(.caption2.monospaced())
                                Text(String(format: "z %.2f", cluster.peakZScore))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(zColor(cluster.peakZScore, family: result.report.family))
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Surface Projections")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(result.surfaceProjections) { projection in
                        HStack {
                            Text(projection.view.displayName)
                                .font(.caption2)
                            Spacer()
                            Text(String(format: "peak %.2f", projection.peakMagnitude))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Structured Report")
                        .font(.system(size: 11, weight: .semibold))
                    Text(result.structuredReport.impression)
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Neuroquant Workbench", systemImage: "brain.head.profile")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func regionRow(_ region: BrainPETRegionStatistic,
                           family: BrainPETAnalysisFamily) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(region.name)
                    .font(.caption2)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.3f", region.suvr))
                    .font(.caption2.monospaced())
            }
            if let z = region.zScore {
                HStack {
                    Text("z")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f", z))
                        .font(.caption2.monospaced())
                        .foregroundStyle(zColor(z, family: family))
                    if let label = region.abnormalityLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(zColor(z, family: family))
                    }
                    Spacer()
                }
            }
        }
    }

    private var normalSources: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(BrainPETNormalDatabaseCatalog.recommendedSources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name)
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(source.access) | \(source.suggestedUse)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(source.url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(TracerTheme.accent)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Normal databases", systemImage: "externaldrive.badge.checkmark")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private var gaainReferenceBuilder: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        scanGAAINReferenceData()
                    } label: {
                        Label("Scan Data Folder", systemImage: "externaldrive.badge.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        exportGAAINBuildPackage()
                    } label: {
                        Label("Export Remote Job", systemImage: "shippingbox.and.arrow.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(gaainSummary == nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task { await launchGAAINOnSpark() }
                } label: {
                    Label(isGAAINRemoteRunning ? "Running Remotely" : "Run Remotely",
                          systemImage: isGAAINRemoteRunning ? "hourglass" : "bolt.horizontal.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isGAAINRemoteRunning)

                Text("Tracer does not bundle GAAIN data. Confirm applicable data-use, citation, and sharing terms before building derived artifacts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if DGXSparkConfig.load().readinessMessage != nil,
                   let detected = DGXSparkConfig.detectedNVIDIASparkProfile(enabled: true) {
                    Button {
                        detected.save()
                        gaainStatus = "Applied detected remote workstation profile: \(detected.sshDestination)"
                    } label: {
                        Label("Use Detected Remote Profile", systemImage: "bolt.horizontal.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let summary = gaainSummary {
                    VStack(alignment: .leading, spacing: 5) {
                        metric("Files", "\(summary.completeFileCount)/\(summary.files.count)")
                        metric("Downloaded", formatBytes(summary.totalActualBytes))
                        ForEach(summary.tracerSummaries.prefix(6)) { tracerSummary in
                            HStack {
                                Text(tracerSummary.tracer.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(tracerSummary.completeFileCount)")
                                    .font(.caption2.monospaced())
                                Text(formatBytes(tracerSummary.actualBytes))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(TracerTheme.viewportBackground.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }

                if let package = gaainPackage {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Remote package ready", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(package.rootURL.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
                if !gaainStatus.isEmpty {
                    Text(gaainStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("GAAIN data import", systemImage: "cpu")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value.isEmpty ? "--" : value)
                .font(.caption2.monospaced())
                .lineLimit(1)
        }
    }

    private func scanGAAINReferenceData() {
        do {
            let summary = try GAAINReferencePipeline.discover()
            gaainSummary = summary
            gaainPackage = nil
            gaainStatus = "Found \(summary.completeFileCount)/\(summary.files.count) public GAAIN files."
        } catch {
            gaainSummary = nil
            gaainPackage = nil
            gaainStatus = "GAAIN scan failed: \(error.localizedDescription)"
        }
    }

    private func exportGAAINBuildPackage() {
        let operationID = "brain-pet-gaain-reference-package"
        JobManager.shared.start(JobUpdate(
            operationID: operationID,
            kind: .brainPETReference,
            title: "GAAIN data import package",
            stage: "Exporting",
            detail: "Writing remote build plan",
            progress: 0.2,
            systemImage: "brain.head.profile",
            canCancel: false
        ))
        do {
            let package = try GAAINReferencePipeline.writeBuildPackage()
            gaainSummary = package.summary
            gaainPackage = package
            gaainStatus = "Remote package ready at \(package.rootURL.path)"
            JobManager.shared.succeed(operationID: operationID,
                                      detail: "GAAIN data import package exported with \(package.plan.jobs.count) tracer job(s)")
        } catch {
            gaainPackage = nil
            gaainStatus = "GAAIN package export failed: \(error.localizedDescription)"
            JobManager.shared.fail(operationID: operationID,
                                   error: JobErrorInfo(error,
                                                       code: "gaain_reference_package_failed",
                                                       recoverySuggestion: "Confirm the GAAIN downloads and manifest exist in Tracer's app-support folder.",
                                                       isRetryable: true))
        }
    }

    private func launchGAAINOnSpark() async {
        guard !isGAAINRemoteRunning else { return }
        let operationID = "brain-pet-gaain-reference-spark"
        var cfg = DGXSparkConfig.load()
        if cfg.readinessMessage != nil,
           let detected = DGXSparkConfig.detectedNVIDIASparkProfile(enabled: true) {
            detected.save()
            cfg = detected
            gaainStatus = "Applied detected remote workstation profile: \(detected.sshDestination). Preparing remote import..."
        }
        guard cfg.enabled, cfg.isConfigured else {
            gaainStatus = cfg.readinessMessage ?? "Enable and configure Remote Workstation in Settings before launching the GAAIN data import."
            JobManager.shared.start(JobUpdate(
                operationID: operationID,
                kind: .brainPETReference,
                title: "GAAIN remote data import",
                stage: "Configuration",
                detail: gaainStatus,
                progress: nil,
                systemImage: "exclamationmark.triangle",
                canCancel: false
            ))
            JobManager.shared.fail(operationID: operationID,
                                   error: JobErrorInfo(code: "dgx_not_configured",
                                                       message: gaainStatus,
                                                       recoverySuggestion: "Open Settings -> Remote Workstation, set the host/user/workdir, and enable remote execution.",
                                                       isRetryable: true))
            return
        }

        isGAAINRemoteRunning = true
        gaainStatus = "Preparing GAAIN remote data import..."
        JobManager.shared.start(JobUpdate(
            operationID: operationID,
            kind: .brainPETReference,
            title: "GAAIN remote data import",
            stage: "Preparing",
            detail: "Exporting local build package",
            progress: nil,
            systemImage: "brain.head.profile",
            canCancel: false
        ))
        defer { isGAAINRemoteRunning = false }

        do {
            let package = try GAAINReferencePipeline.writeBuildPackage()
            gaainSummary = package.summary
            gaainPackage = package
            JobManager.shared.update(operationID: operationID,
                                     stage: "Remote",
                                     detail: "Uploading package and launching worker")

            let sink: @Sendable (String) -> Void = { text in
                let detail = text
                    .split(whereSeparator: \.isNewline)
                    .last
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let detail, !detail.isEmpty else { return }
                Task { @MainActor in
                    gaainStatus = detail
                    JobManager.shared.heartbeat(operationID: operationID,
                                                detail: detail)
                }
            }
            let result = try await Task.detached(priority: .utility) {
                let runner = RemoteGAAINReferenceBuilder(configuration: .init(dgx: cfg))
                return try runner.run(package: package, logSink: sink)
            }.value

            gaainStatus = "Remote import complete: \(result.artifactPaths.count) artifact(s) pulled to \(result.localOutputRoot.path)"
            JobManager.shared.succeed(operationID: operationID,
                                      detail: gaainStatus)
        } catch {
            gaainStatus = "GAAIN remote data import failed: \(error.localizedDescription)"
            JobManager.shared.fail(operationID: operationID,
                                   error: JobErrorInfo(error,
                                                       code: "gaain_spark_build_failed",
                                                       recoverySuggestion: "Check Settings -> Remote Workstation, Python/nibabel/numpy availability on the remote workstation, disk space, and the Job Center log.",
                                                       isRetryable: true))
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }

    private func icon(for family: BrainPETAnalysisFamily) -> String {
        switch family {
        case .fdg: return "bolt.heart"
        case .amyloid: return "aqi.medium"
        case .tau: return "point.3.connected.trianglepath.dotted"
        case .spectPerfusion: return "waveform.path.ecg"
        case .dopamineTransporter: return "circle.grid.cross"
        case .generic: return "chart.xyaxis.line"
        }
    }

    private func zColor(_ z: Double, family: BrainPETAnalysisFamily) -> Color {
        switch family {
        case .fdg, .spectPerfusion, .dopamineTransporter:
            return z <= -2 ? .red : .secondary
        case .amyloid, .tau:
            return z >= 2 ? .orange : .secondary
        case .generic:
            return abs(z) >= 2 ? .orange : .secondary
        }
    }

    private func confidenceColor(_ confidence: BrainPETAnatomyConfidence) -> Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .secondary
        }
    }
}
