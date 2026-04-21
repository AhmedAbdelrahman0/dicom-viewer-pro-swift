# DICOM Viewer Pro — SwiftUI

A native SwiftUI version of DICOM Viewer Pro that runs on **macOS 14+** and **iPadOS 17+**.

## Features

- **MPR Views**: Axial, Sagittal, Coronal + 3D MIP — all running natively on CoreGraphics
- **Native NIfTI parser**: Pure Swift, supports `.nii` and `.nii.gz` with built-in gzip decompression
- **Native DICOM parser**: Explicit & Implicit VR Little Endian, uncompressed pixel data
- **PET/CT Fusion**: 9 colormaps (hot, pet_rainbow, jet, bone, cool_warm, fire, ice, grayscale, inverted_gray)
- **Tools**: W/L, Pan, Zoom, Distance, Angle, Area measurements
- **Orientation markers**: R/L/A/P/H/F overlays on every view
- **W/L Presets**: Auto-switching based on modality (CT / MR / PET)
- **SwiftUI-native**: Dark theme, pinch-to-zoom on iPad, keyboard shortcuts on Mac

## Architecture

Pure Swift 5.9+ using **no third-party dependencies** — everything works with Apple's frameworks:

- **SwiftUI** — UI
- **CoreGraphics** — pixel rendering
- **Compression** — gzip for `.nii.gz`
- **ImageIO** — image handling

## Project Structure

```
Sources/
├── DicomViewerPro/              # Library (reusable)
│   ├── App/
│   │   └── DicomViewerApp.swift         # @main app scene
│   ├── Models/
│   │   ├── ImageVolume.swift            # 3D volume data type
│   │   ├── WindowLevel.swift            # W/L presets
│   │   ├── Annotation.swift             # Measurements model
│   │   └── FusionPair.swift             # Fusion + colormaps
│   ├── IO/
│   │   ├── NIfTILoader.swift            # Native .nii/.nii.gz parser
│   │   └── DICOMLoader.swift            # Native DICOM parser
│   ├── Rendering/
│   │   ├── Colormaps.swift              # LUT generation
│   │   └── PixelRenderer.swift          # Float → CGImage
│   ├── ViewModels/
│   │   └── ViewerViewModel.swift        # @MainActor state holder
│   └── Views/
│       ├── ContentView.swift            # NavigationSplitView root
│       ├── SliceView.swift              # Single MPR view + gestures
│       ├── StudyBrowserView.swift       # Left sidebar
│       └── ControlsPanel.swift          # Right sidebar (W/L, Fusion, …)
└── DicomViewerProApp/
    └── main.swift                       # Executable entry point
```

## Building

### Command Line (macOS)

```bash
cd DicomViewerProSwift
swift build                              # Build
swift run DicomViewerProApp              # Run on macOS
```

### Xcode (macOS + iPad)

```bash
open Package.swift                       # Opens the SwiftPM package in Xcode
```

Then in Xcode:
1. Select the `DicomViewerProApp` scheme
2. Pick target: **"My Mac"** or **"Any iOS Device"** / iPad simulator
3. Press **⌘R** to run

## Usage

### Keyboard Shortcuts (macOS)
- **⌘O** — Open DICOM directory
- **⌘N** — Open NIfTI file

### Tools
Select a tool from the toolbar, then drag on any slice view:

| Tool | Action |
|------|--------|
| W/L | Drag horizontally for window, vertically for level |
| Pan | Drag to move the image |
| Zoom | Drag vertically to zoom in/out |
| Distance | Tap two points |
| Angle | Tap three points (arm 1 → vertex → arm 2) |
| Area | Tap 3+ points to define polygon |

### Touch (iPad)
- **Pinch** to zoom
- **Two-finger drag** to pan
- **Tap** for measurements
- **Double-tap** to reset zoom

## Supported Files

- DICOM: `*.dcm`, `*.DCM`, `.IMA` (uncompressed pixel data only)
- NIfTI: `*.nii`, `*.nii.gz`

## Labeling & Segmentation Pipeline

Full multimodality labeling support with emphasis on PET/CT:

### Features
- **3D label maps** (`UInt16` voxels) aligned to each parent volume
- **Cross-linked MPR views** — world-space crosshair syncs across all views
- **Landmark-based rigid registration** — click matching anatomical points in fixed
  and moving volumes; SVD-based Horn 1987 closed-form solution computes the
  best rigid transform with TRE reporting
- **Label migration** — transfer labels from one volume to a fused/registered
  volume through the computed transform (nearest-neighbor resampling)

### Tools
| Tool | Purpose |
|------|---------|
| **Brush / Eraser** | Manual 2D or 3D spherical painting (1–20 voxel radius) |
| **SUV Threshold** | Fixed threshold (e.g. SUV ≥ 2.5) across whole volume |
| **40% SUVmax** | EANM-standard PET tumor segmentation around a seed |
| **SUV Gradient** | Seeded PET edge segmentation with SUV floor and gradient-boundary stopping |
| **Region Growing** | Flood-fill connected voxels within tolerance of seed |
| **Grow / Shrink** | Margin-style morphological clean-up |
| **Islands** | Keep largest connected component or remove small islands |
| **Logical** | Union / replace one class into another in the current labelmap |
| **Landmark** | Click matching points for rigid registration |

### Built-in Label Presets (all known schemes)
- **TotalSegmentator** — 104 anatomical structures (organs, vessels, bones, muscles)
- **AutoPET** — FDG-PET/CT lesion classification
- **BraTS** — Brain tumor (edema, core, enhancing, necrotic)
- **AMOS** — 15 abdominal organs
- **MSD** — Liver, Lung, Pancreas, Prostate
- **RT Standard** — ICRU 50/62/83 target volumes (GTV, CTV, ITV, PTV, Boost)
- **PET Focal Uptake** — Primary, nodal, metastatic, physiological, inflammation
- **Oncology Clinical** — Primary, nodes, mets, recurrence, response
- **H&N, Thorax, Abdominal, Pelvic OARs** — Radiotherapy organs at risk
- **Brain Lobes** — Major cerebral regions
- **Spine Vertebrae** — C1–L5 individually labeled

### Annotation File Formats
- **DICOM Viewer Labels** (`.dvlabels`) — native package with label voxels, classes, annotations, landmarks, and geometry
- **NIfTI labelmap** (`.nii` / `.nii.gz`) — integer mask
- **NRRD labelmap** (`.nrrd`) import/export
- **3D Slicer segmentation** (`.seg.nrrd`) import/export with segment metadata
- **ITK-SNAP** (`.nii` + `.label.txt` sidecar)
- **DICOM RTSTRUCT** (read) — parses contour sequences and rasterizes to voxel grid
- **JSON annotations** (COCO/CVAT-compatible subset)
- **CSV landmarks**

### PET-Specific Statistics
For each labeled region, automatically computes: voxel count, volume (cm³), mean,
max, min, std, SUV max, SUV mean, SUV peak, and **TLG** (Total Lesion Glycolysis).

## Limitations

- DICOM JPEG-compressed pixel data not yet supported
- DICOM SEG export not yet implemented
- Exclusive labelmaps are used, so overlapping Slicer segments are flattened on import/export

## License

Research/educational use.
