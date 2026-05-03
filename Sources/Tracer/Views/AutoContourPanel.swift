import SwiftUI

struct AutoContourPanel: View {
    @EnvironmentObject private var vm: ViewerViewModel
    @EnvironmentObject private var monai: MONAILabelViewModel
    @EnvironmentObject private var nnunet: NNUnetViewModel

    @State private var selectedTemplateID: String = AutoContourWorkflow.templates.first?.id ?? ""
    @State private var isRunning = false

    private var selectedTemplate: AutoContourProtocolTemplate? {
        AutoContourWorkflow.template(id: selectedTemplateID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            protocolPicker
            actionGrid
            if let session = vm.autoContourSession {
                sessionSummary(session)
                structurePlanList(session)
            }
            qaSection
        }
        .padding(16)
        .onAppear {
            if selectedTemplateID.isEmpty {
                selectedTemplateID = AutoContourWorkflow.templates.first?.id ?? ""
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.square.badge.checkmark")
                .foregroundStyle(TracerTheme.accent)
            Text("Auto Contour")
                .font(.headline)
            Spacer()
            if isRunning || nnunet.isRunning || monai.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var protocolPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Protocol")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("Protocol", selection: $selectedTemplateID) {
                ForEach(AutoContourWorkflow.templates) { template in
                    Text(template.displayName).tag(template.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if let selectedTemplate {
                HStack(spacing: 6) {
                    Label(selectedTemplate.clinicalPerspective.rawValue,
                          systemImage: perspectiveIcon(selectedTemplate.clinicalPerspective))
                    Label(selectedTemplate.modalities.map(\.displayName).joined(separator: "/"),
                          systemImage: "rectangle.stack")
                    if let entry = selectedTemplate.preferredNNUnetEntryID.flatMap(NNUnetCatalog.byID) {
                        Label(entry.displayName, systemImage: "brain")
                    } else {
                        Label("Protocol QA", systemImage: "checklist")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
    }

    private var actionGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    planSelectedProtocol()
                } label: {
                    Label("Plan", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectedTemplate == nil || vm.currentVolume == nil)

                Button {
                    vm.prepareAutoContourStructureSet(templateID: selectedTemplateID)
                } label: {
                    Label("Prepare", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectedTemplate == nil || vm.currentVolume == nil)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await runSelectedProtocol() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isRunning || selectedTemplate == nil || vm.currentVolume == nil)

                Button {
                    vm.refreshAutoContourQA(templateID: selectedTemplateID)
                } label: {
                    Label("QA", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.labeling.activeLabelMap == nil)
            }

            Button {
                vm.approveAutoContourSession()
            } label: {
                Label("Approve", systemImage: "checkmark.seal.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.autoContourSession == nil ||
                      vm.labeling.activeLabelMap == nil ||
                      (vm.autoContourQAReport?.hasBlockingFindings ?? true))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func sessionSummary(_ session: AutoContourSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(session.status.rawValue, systemImage: statusIcon(session.status))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor(session.status))
                Spacer()
                Text("\(session.routedStructureCount)/\(session.structurePlans.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let preferred = session.preferredNNUnetEntry {
                Text("Preferred: \(preferred.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let route = session.primaryRoute {
                Text("Route: \(route.modelName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Label(session.protocolTemplate.clinicalPerspective.rawValue,
                  systemImage: perspectiveIcon(session.protocolTemplate.clinicalPerspective))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !session.volumeDescription.isEmpty {
                Text(session.volumeDescription)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TracerTheme.viewportBackground.opacity(0.68))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(TracerTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func structurePlanList(_ session: AutoContourSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Structures")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(session.structurePlans.prefix(18)) { plan in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(plan.template.color)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.template.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text(plan.backendLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(plan.template.priority.rawValue)
                            .font(.caption2.monospaced())
                            .foregroundStyle(priorityColor(plan.template.priority))
                    }
                }
            }
            if session.structurePlans.count > 18 {
                Text("+\(session.structurePlans.count - 18) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var qaSection: some View {
        if let report = vm.autoContourQAReport {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(report.compactSummary,
                          systemImage: report.hasBlockingFindings ? "xmark.octagon" : "checkmark.seal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(report.hasBlockingFindings ? Color.red : Color.orange)
                    Spacer()
                }

                if report.findings.isEmpty {
                    Text("Ready for physician review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(report.findings.prefix(8)) { finding in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: findingIcon(finding.severity))
                                    .foregroundStyle(findingColor(finding.severity))
                                    .frame(width: 14)
                                Text(finding.structureName.map { "\($0): \(finding.message)" } ?? finding.message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TracerTheme.viewportBackground.opacity(0.68))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(TracerTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func planSelectedProtocol() {
        let models = monai.info?.modelNames ?? []
        vm.planAutoContour(templateID: selectedTemplateID, availableMONAIModels: models)
    }

    private func runSelectedProtocol() async {
        guard let template = selectedTemplate else { return }
        isRunning = true
        defer { isRunning = false }

        let session = vm.planAutoContour(templateID: template.id,
                                         availableMONAIModels: monai.info?.modelNames ?? [])
        guard let session else { return }

        if let preferred = session.preferredNNUnetEntry {
            await runNNUnet(entry: preferred, template: template)
            return
        }

        if let route = session.primaryRoute,
           monai.isConnected,
           let model = monai.selectBestModel(for: route) {
            await runMONAI(model: model, route: route, template: template)
            return
        }

        vm.prepareAutoContourStructureSet(templateID: template.id)
        vm.refreshAutoContourQA(templateID: template.id)
        vm.statusMessage = "Prepared \(template.shortName) review workflow; connect MONAI or install nnU-Net weights to run inference"
    }

    private func runNNUnet(entry: NNUnetCatalog.Entry,
                           template: AutoContourProtocolTemplate) async {
        nnunet.selectedEntryID = entry.id
        guard let primary = vm.autoContourPrimaryVolume(for: entry, template: template) else {
            vm.statusMessage = "No compatible primary volume for \(entry.displayName)"
            return
        }
        let auxiliaries = vm.autoContourAuxiliaryChannels(for: entry, primary: primary)
        if entry.requiredChannels > 1, auxiliaries.count < entry.requiredChannels - 1 {
            vm.statusMessage = "Auto-contour needs \(entry.channelDescriptions.joined(separator: " + ")) channels"
            return
        }
        guard let labelMap = await nnunet.run(on: primary,
                                              auxiliaryChannels: auxiliaries,
                                              labeling: vm.labeling) else {
            vm.statusMessage = nnunet.statusMessage
            return
        }
        vm.completeAutoContourInference(
            labelMap: labelMap,
            templateID: template.id,
            engine: "nnU-Net",
            backend: nnunet.mode.displayName,
            modelID: entry.datasetID,
            metadata: [
                "autoContour.channelCount": "\(1 + auxiliaries.count)",
                "autoContour.primaryVolume": primary.sessionIdentity
            ]
        )
        vm.saveCurrentStudySession(named: "Auto Contour")
    }

    private func runMONAI(model: String,
                          route: SegmentationRAGPlan,
                          template: AutoContourProtocolTemplate) async {
        guard let volume = vm.autoContourPrimaryVolume(for: template) else {
            vm.statusMessage = "No compatible volume for MONAI auto-contour"
            return
        }
        monai.selectedModel = model
        guard let labelMap = await monai.runInference(on: volume, in: vm.labeling) else {
            vm.statusMessage = monai.statusMessage
            return
        }
        vm.completeAutoContourInference(
            labelMap: labelMap,
            templateID: template.id,
            engine: "MONAI Label",
            backend: monai.serverURL,
            modelID: model,
            metadata: [
                "autoContour.primaryRoute": route.modelName,
                "autoContour.primaryVolume": volume.sessionIdentity
            ]
        )
        vm.saveCurrentStudySession(named: "Auto Contour")
    }

    private func statusIcon(_ state: AutoContourReviewState) -> String {
        switch state {
        case .notStarted: return "circle"
        case .planned: return "checklist"
        case .running: return "play.circle"
        case .draft: return "doc.badge.gearshape"
        case .needsReview: return "person.crop.square.badge.exclamationmark"
        case .approved: return "checkmark.seal.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    private func statusColor(_ state: AutoContourReviewState) -> Color {
        switch state {
        case .approved: return .green
        case .blocked: return .red
        case .needsReview, .draft: return .orange
        default: return .secondary
        }
    }

    private func priorityColor(_ priority: AutoContourStructurePriority) -> Color {
        switch priority {
        case .required: return .red
        case .recommended: return .orange
        case .optional: return .secondary
        }
    }

    private func findingIcon(_ severity: AutoContourQAFindingSeverity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func findingColor(_ severity: AutoContourQAFindingSeverity) -> Color {
        switch severity {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func perspectiveIcon(_ perspective: AutoContourClinicalPerspective) -> String {
        switch perspective {
        case .radiationOncology: return "scope"
        case .nuclearRadiology: return "atom"
        case .neuroOncology: return "brain.head.profile"
        }
    }
}
