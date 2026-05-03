import SwiftUI

struct PACSAdminPanel: View {
    @ObservedObject var vm: ViewerViewModel
    let indexedStudies: [PACSWorklistStudy]
    let onApplyMetadata: (PACSStudyMetadataDraft, PACSWorklistStudy) -> Void
    let onRetireStudy: (PACSWorklistStudy) -> Void
    let onCreateDICOMSeries: (DICOMSeriesCreationDraft) -> Void

    @State private var selectedStudyID: String?
    @State private var metadataDraft = PACSStudyMetadataDraft()
    @State private var creationDraft = DICOMSeriesCreationDraft()
    @State private var confirmRetire = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                studySelectorSection

                if let study = selectedStudy {
                    metadataSection(study)
                }

                dicomCreationSection
            }
            .padding(8)
        }
        .scrollContentBackground(.hidden)
        .background(TracerTheme.sidebarBackground)
        .onAppear(perform: ensureSelection)
        .onChange(of: indexedStudies.map(\.id)) { _, _ in ensureSelection() }
        .onChange(of: selectedStudyID) { _, _ in syncMetadataDraft() }
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
            return
        }
        metadataDraft = PACSStudyMetadataDraft(study: selectedStudy)
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
