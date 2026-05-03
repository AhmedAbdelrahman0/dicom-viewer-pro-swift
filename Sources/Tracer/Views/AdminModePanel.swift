import SwiftUI

struct PACSAdminPanel: View {
    @ObservedObject var vm: ViewerViewModel
    let indexedStudies: [PACSWorklistStudy]
    let auditEvents: [PACSAdminAuditEvent]
    let routeQueue: [PACSAdminRouteQueueItem]
    let onApplyMetadata: (PACSStudyMetadataDraft, PACSWorklistStudy) -> Void
    let onApplySnapshots: ([PACSIndexedSeriesSnapshot], String, PACSAdminAuditEventKind) -> Void
    let onRetireStudy: (PACSWorklistStudy) -> Void
    let onCreateDICOMSeries: (DICOMSeriesCreationDraft) -> Void
    let onQueueRoute: (PACSWorklistStudy) -> Void
    let onSendRoute: (PACSWorklistStudy) -> Void
    let onClearCompletedRoutes: () -> Void
    let onClearAudit: () -> Void

    @State private var selectedStudyID: String?
    @State private var metadataDraft = PACSStudyMetadataDraft()
    @State private var creationDraft = DICOMSeriesCreationDraft()
    @State private var tagEdit = PACSAdminTagEditDraft()
    @State private var batchDraft = PACSAdminBatchOperationDraft()
    @State private var deIDOptions = PACSAdminDeidentificationOptions()
    @State private var uidPlan = PACSAdminUIDPlan()
    @State private var topologyOperation: PACSAdminTopologyOperation = .splitSeriesToStudies
    @State private var workflowRules = PACSAdminWorkflowRule.defaults
    @State private var confirmRetire = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                studySelectorSection

                if let study = selectedStudy {
                    metadataSection(study)
                    tagEditorSection(study)
                    uidAndTopologySection(study)
                    routingSection(study)
                }

                batchSection
                deidentificationSection
                dicomCreationSection
                quarantineSection
                workflowRulesSection
                healthSection
                auditSection
            }
            .padding(8)
        }
        .scrollContentBackground(.hidden)
        .background(TracerTheme.sidebarBackground)
        .onAppear(perform: ensureSelection)
        .onChange(of: indexedStudies.map(\.id)) { _, _ in ensureSelection() }
        .onChange(of: selectedStudyID) { _, _ in syncMetadataDraft() }
        .onChange(of: tagEdit.tag) { _, _ in syncTagValue() }
        .confirmationDialog("Retire study from index?",
                            isPresented: $confirmRetire,
                            titleVisibility: .visible) {
            if let study = selectedStudy {
                Button("Retire Index Record", role: .destructive) {
                    onRetireStudy(study)
                    ensureSelection()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var selectedStudy: PACSWorklistStudy? {
        guard let selectedStudyID else { return indexedStudies.first }
        return indexedStudies.first { $0.id == selectedStudyID } ?? indexedStudies.first
    }

    private var studySelectorSection: some View {
        adminSection(title: "PACS Admin", systemImage: "server.rack") {
            if indexedStudies.isEmpty {
                emptyState(
                    systemImage: "tray",
                    title: "No Indexed Studies",
                    subtitle: "Index or create DICOM studies first"
                )
            } else {
                Picker("Study", selection: selectedStudyBinding) {
                    ForEach(indexedStudies) { study in
                        Text(studyTitle(study)).tag(study.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)

                if let study = selectedStudy {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(studyTitle(study))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                        Text(studySummary(study))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func metadataSection(_ study: PACSWorklistStudy) -> some View {
        adminSection(title: "Index Metadata", systemImage: "pencil.and.list.clipboard") {
            adminTextField("Study name", text: $metadataDraft.studyDescription)
            adminTextField("Patient name", text: $metadataDraft.patientName)
            adminTextField("Patient ID", text: $metadataDraft.patientID)
            adminTextField("Accession", text: $metadataDraft.accessionNumber)

            HStack(spacing: 6) {
                adminTextField("Date", text: $metadataDraft.studyDate)
                adminTextField("Time", text: $metadataDraft.studyTime)
            }

            adminTextField("Referring physician", text: $metadataDraft.referringPhysicianName)
            adminTextField("Body part", text: $metadataDraft.bodyPartExamined)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    metadataButtons(study)
                }
                VStack(spacing: 6) {
                    metadataButtons(study)
                }
            }
            .padding(.top, 2)
        }
    }

    private func metadataButtons(_ study: PACSWorklistStudy) -> some View {
        Group {
            Button {
                onApplyMetadata(metadataDraft, study)
            } label: {
                Label("Apply", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!metadataHasChanges(for: study))

            Button {
                metadataDraft = .anonymized(from: study)
            } label: {
                Label("Anonymize", systemImage: "person.crop.circle.badge.xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                confirmRetire = true
            } label: {
                Label("Retire", systemImage: "archivebox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var dicomCreationSection: some View {
        adminSection(title: "Create DICOM", systemImage: "doc.badge.plus") {
            adminTextField("Study name", text: $creationDraft.studyDescription)
            adminTextField("Series name", text: $creationDraft.seriesDescription)
            adminTextField("Patient name", text: $creationDraft.patientName)
            adminTextField("Patient ID", text: $creationDraft.patientID)
            adminTextField("Accession", text: $creationDraft.accessionNumber)

            Picker("Modality", selection: $creationDraft.modality) {
                ForEach(PACSAdminDICOMModality.allCases) { modality in
                    Text(modality.displayName).tag(modality)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            VStack(spacing: 4) {
                Stepper("Rows \(creationDraft.rows)", value: $creationDraft.rows, in: 1...512, step: 16)
                Stepper("Columns \(creationDraft.columns)", value: $creationDraft.columns, in: 1...512, step: 16)
                Stepper("Slices \(creationDraft.slices)", value: $creationDraft.slices, in: 1...256)
            }
            .font(.system(size: 11))
            .controlSize(.small)

            if let message = creationDraft.validationMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Text(PACSAdminDICOMFactory.defaultOutputRoot.path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Button {
                onCreateDICOMSeries(creationDraft)
            } label: {
                Label("Create and Index", systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(creationDraft.validationMessage != nil)
        }
    }

    private func tagEditorSection(_ study: PACSWorklistStudy) -> some View {
        let diffRows = tagEdit.diffRows(for: study)
        return adminSection(title: "DICOM Tags", systemImage: "tag") {
            HStack(spacing: 6) {
                Picker("Tag", selection: $tagEdit.tag) {
                    ForEach(PACSAdminSupportedTag.allCases) { tag in
                        Text("\(tag.tag) \(tag.displayName)").tag(tag)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)

                Text(tagEdit.tag.vr)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            adminTextField(tagEdit.tag.displayName, text: $tagEdit.value)

            if let message = tagEdit.validationMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if !diffRows.isEmpty {
                ForEach(diffRows.prefix(3)) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.scope)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Text("\(row.before.isEmpty ? "-" : row.before) -> \(row.after.isEmpty ? "-" : row.after)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Button {
                onApplySnapshots(tagEdit.applying(to: study.series),
                                 "Applied \(tagEdit.tag.displayName)",
                                 .tagEdit)
            } label: {
                Label("Apply Tag", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(tagEdit.validationMessage != nil || diffRows.isEmpty)
        }
    }

    private var batchSection: some View {
        adminSection(title: "Batch", systemImage: "square.stack.3d.up") {
            Picker("Operation", selection: $batchDraft.kind) {
                ForEach(PACSAdminBatchOperationKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            adminTextField(batchDraft.kind.displayName, text: $batchDraft.value)

            if let message = batchDraft.validationMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Button {
                onApplySnapshots(batchDraft.applying(to: indexedStudies),
                                 "Batch \(batchDraft.kind.displayName)",
                                 .batchEdit)
            } label: {
                Label("Apply to \(indexedStudies.count)", systemImage: "checkmark.rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(indexedStudies.isEmpty || batchDraft.validationMessage != nil)
        }
    }

    private var deidentificationSection: some View {
        let plan = PACSAdminDeidentificationPlan.make(studies: indexedStudies, options: deIDOptions)
        return adminSection(title: "De-ID", systemImage: "person.crop.circle.badge.xmark") {
            Picker("Preset", selection: $deIDOptions.preset) {
                ForEach(PACSAdminDeidentificationPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Toggle("Remap UIDs", isOn: $deIDOptions.remapUIDs)
                .font(.system(size: 11))
                .controlSize(.small)
            Toggle("Keep Dates", isOn: $deIDOptions.keepStudyDate)
                .font(.system(size: 11))
                .controlSize(.small)
            adminTextField("Patient ID prefix", text: $deIDOptions.patientIDPrefix)

            HStack(spacing: 8) {
                Label("\(plan.snapshots.count) series", systemImage: "square.stack")
                Label("\(plan.uidMappings.count) UIDs", systemImage: "number")
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)

            if let warning = plan.warnings.first {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }

            Button {
                onApplySnapshots(plan.snapshots,
                                 "Applied \(deIDOptions.preset.displayName) de-ID",
                                 .deidentify)
            } label: {
                Label("Apply De-ID", systemImage: "lock.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(indexedStudies.isEmpty || deIDOptions.patientIDPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func uidAndTopologySection(_ study: PACSWorklistStudy) -> some View {
        adminSection(title: "UIDs and Topology", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 3) {
                Text(study.studyUID.isEmpty ? "No Study UID" : study.studyUID)
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(study.seriesCount) series | \(study.instanceCount) instances")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Toggle("Study UID", isOn: $uidPlan.regenerateStudyUID)
                .font(.system(size: 11))
                .controlSize(.small)
            Toggle("Series UIDs", isOn: $uidPlan.regenerateSeriesUIDs)
                .font(.system(size: 11))
                .controlSize(.small)

            Button {
                let planned = uidPlan.applying(to: study)
                onApplySnapshots(planned.snapshots,
                                 "Regenerated \(planned.mappings.count) UIDs",
                                 .uidRemap)
            } label: {
                Label("Regenerate UIDs", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!uidPlan.regenerateStudyUID && !uidPlan.regenerateSeriesUIDs)

            Picker("Topology", selection: $topologyOperation) {
                ForEach(PACSAdminTopologyOperation.allCases) { operation in
                    Text(operation.displayName).tag(operation)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Button {
                let snapshots: [PACSIndexedSeriesSnapshot]
                switch topologyOperation {
                case .splitSeriesToStudies:
                    snapshots = PACSAdminTopologyPlanner.splitSeriesToStudies(study)
                case .mergeSameAccessionIntoSelected:
                    snapshots = PACSAdminTopologyPlanner.mergeSameAccession(into: study, from: indexedStudies)
                }
                onApplySnapshots(snapshots,
                                 topologyOperation.displayName,
                                 .topology)
            } label: {
                Label("Apply Topology", systemImage: "arrow.branch")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func routingSection(_ study: PACSWorklistStudy) -> some View {
        adminSection(title: "DICOMweb Route", systemImage: "paperplane") {
            if let connection = vm.activeVNAConnection {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(connection.endpointSummary)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Button {
                        onQueueRoute(study)
                    } label: {
                        Label("Queue", systemImage: "tray")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onSendRoute(study)
                    } label: {
                        Label("Send", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(study.series.allSatisfy { $0.kind != .dicom })
                }
            } else {
                emptyState(systemImage: "network.slash",
                           title: "No Destination",
                           subtitle: "Add a VNA connection")
            }

            ForEach(routeQueue.prefix(3)) { item in
                HStack(spacing: 6) {
                    Image(systemName: routeStatusImage(item.status))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.studyDescription)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        Text("\(item.endpointName) | \(item.message)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }

            if routeQueue.contains(where: { $0.status == .sent }) {
                Button {
                    onClearCompletedRoutes()
                } label: {
                    Label("Clear Sent", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var quarantineSection: some View {
        let findings = PACSAdminQuarantineFinding.evaluate(studies: indexedStudies)
        return adminSection(title: "Quarantine", systemImage: "exclamationmark.shield") {
            if findings.isEmpty {
                Label("Clear", systemImage: "checkmark.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                ForEach(findings.prefix(5)) { finding in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finding.title)
                                .font(.system(size: 10, weight: .medium))
                            Text(finding.detail)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: finding.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundColor(finding.severity == .error ? .red : .orange)
                    }
                }
            }
        }
    }

    private var workflowRulesSection: some View {
        adminSection(title: "Workflow Rules", systemImage: "slider.horizontal.2.square.on.square") {
            ForEach($workflowRules) { $rule in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(rule.name, isOn: $rule.isEnabled)
                        .font(.system(size: 11, weight: .medium))
                        .controlSize(.small)

                    let matchCount = indexedStudies.filter { rule.matches($0) }.count
                    Text("\(matchCount) match | \(rule.actions.map(\.displayName).joined(separator: ", "))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var healthSection: some View {
        let findings = PACSAdminQuarantineFinding.evaluate(studies: indexedStudies)
        let health = PACSAdminHealthSnapshot.make(
            studies: indexedStudies,
            vnaConnectionCount: vm.vnaConnections.count,
            routeQueueCount: routeQueue.count,
            quarantineIssueCount: findings.count
        )
        return adminSection(title: "Health", systemImage: "heart.text.square") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                healthMetric("Studies", health.studyCount)
                healthMetric("Series", health.seriesCount)
                healthMetric("Instances", health.instanceCount)
                healthMetric("VNAs", health.vnaConnectionCount)
                healthMetric("Routes", health.routeQueueCount)
                healthMetric("Issues", health.quarantineIssueCount)
            }
        }
    }

    private var auditSection: some View {
        adminSection(title: "Audit", systemImage: "list.bullet.clipboard") {
            if auditEvents.isEmpty {
                emptyState(systemImage: "list.bullet.clipboard",
                           title: "No Audit Events",
                           subtitle: "Admin actions appear here")
            } else {
                ForEach(auditEvents.prefix(6)) { event in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.summary)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(2)
                        Text("\(event.kind.rawValue) | \(event.timestamp.formatted(date: .numeric, time: .shortened))")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    onClearAudit()
                } label: {
                    Label("Clear Audit", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var selectedStudyBinding: Binding<String?> {
        Binding(
            get: { selectedStudy?.id },
            set: { id in
                selectedStudyID = id
                syncMetadataDraft()
            }
        )
    }

    private func adminTextField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.system(size: 11))
    }

    private func adminSection<Content: View>(title: String,
                                             systemImage: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TracerTheme.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(TracerTheme.hairline)
        )
    }

    private func emptyState(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func healthMetric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(TracerTheme.panelBackground)
        )
    }

    private func routeStatusImage(_ status: PACSAdminRouteStatus) -> String {
        switch status {
        case .queued: return "tray"
        case .sending: return "arrow.up.circle"
        case .sent: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        }
    }

    private func ensureSelection() {
        if let selectedStudyID,
           indexedStudies.contains(where: { $0.id == selectedStudyID }) {
            syncMetadataDraft()
            return
        }
        selectedStudyID = indexedStudies.first?.id
        syncMetadataDraft()
    }

    private func syncMetadataDraft() {
        guard let selectedStudy else {
            metadataDraft = PACSStudyMetadataDraft()
            tagEdit.value = ""
            return
        }
        metadataDraft = PACSStudyMetadataDraft(study: selectedStudy)
        syncTagValue()
    }

    private func syncTagValue() {
        guard let selectedStudy,
              let firstSeries = selectedStudy.series.first else {
            tagEdit.value = ""
            return
        }
        tagEdit.value = tagEdit.tag.value(from: firstSeries)
    }

    private func metadataHasChanges(for study: PACSWorklistStudy) -> Bool {
        metadataDraft != PACSStudyMetadataDraft(study: study)
    }

    private func studyTitle(_ study: PACSWorklistStudy) -> String {
        firstMeaningful(study.studyDescription, study.patientName, study.id)
    }

    private func studySummary(_ study: PACSWorklistStudy) -> String {
        let patient = firstMeaningful(study.patientName, "Unknown patient")
        let accession = study.accessionNumber.isEmpty ? "No accession" : study.accessionNumber
        return "\(patient) | \(study.modalitySummary) | \(study.seriesCount) series | \(accession)"
    }

    private func firstMeaningful(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
