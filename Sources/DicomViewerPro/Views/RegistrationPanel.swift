import SwiftUI
import simd

struct RegistrationPanel: View {
    @EnvironmentObject var vm: ViewerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Registration")
                    .font(.headline)

                // Crosshair sync toggle
                Toggle("Cross-link Views", isOn: $vm.labeling.crosshair.enabled)

                Divider()

                Text("Landmark Registration")
                    .font(.headline)
                Text("Click matching anatomical points in the fixed and moving volumes to build a rigid transform.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Next point", selection: $vm.labeling.landmarkCaptureTarget) {
                    ForEach(LandmarkCaptureTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                if vm.labeling.pendingFixedLandmark != nil || vm.labeling.pendingMovingLandmark != nil {
                    HStack {
                        Label("One point pending", systemImage: "mappin")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Cancel") {
                            vm.labeling.cancelPendingLandmark()
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    Text("Landmarks: \(vm.labeling.landmarks.count)")
                    Spacer()
                    if vm.labeling.treMM > 0 {
                        Text(String(format: "TRE: %.2f mm", vm.labeling.treMM))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(vm.labeling.treMM < 3 ? .green : .orange)
                    }
                }

                if !vm.labeling.landmarks.isEmpty {
                    ForEach(vm.labeling.landmarks) { lm in
                        LandmarkRow(landmark: lm, onDelete: {
                            vm.labeling.removeLandmark(id: lm.id)
                        })
                    }
                }

                HStack {
                    Button {
                        vm.labeling.updateTransform()
                    } label: {
                        Label("Compute", systemImage: "function")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(vm.labeling.landmarks.count < 3)

                    Button(role: .destructive) {
                        vm.labeling.clearLandmarks()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()

                // Transform display
                Text("Current Transform")
                    .font(.headline)
                TransformMatrixView(transform: vm.labeling.currentTransform)

                Divider()

                // Label migration
                Text("Label Migration")
                    .font(.headline)
                Text("Transfer the active label map to the fused / target volume using the current transform.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    if let src = vm.currentVolume,
                       let tgt = vm.fusion?.displayedOverlay ?? vm.loadedVolumes.last(where: { $0.seriesUID != vm.currentVolume?.seriesUID }) {
                        _ = vm.labeling.migrateActiveLabel(sourceVolume: src, toTarget: tgt)
                    }
                } label: {
                    Label("Migrate Active Label to Fused Volume",
                          systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(vm.labeling.activeLabelMap == nil)

                Spacer()
            }
            .padding()
        }
    }
}

private struct LandmarkRow: View {
    let landmark: LandmarkPair
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(landmark.label.isEmpty ? "Landmark" : landmark.label)
                    .font(.system(size: 11, weight: .semibold))
                Text(String(format: "F: %.1f, %.1f, %.1f",
                            landmark.fixed.x, landmark.fixed.y, landmark.fixed.z))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(String(format: "M: %.1f, %.1f, %.1f",
                            landmark.moving.x, landmark.moving.y, landmark.moving.z))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(4)
    }
}

private struct TransformMatrixView: View {
    let transform: Transform3D

    var body: some View {
        let m = transform.matrix
        VStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { col in
                        Text(String(format: "%.3f", m[col, row]))
                            .font(.system(size: 9, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(4)
    }
}
