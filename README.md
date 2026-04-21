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

## Limitations

- DICOM JPEG-compressed pixel data not yet supported
- No 3D volume rendering yet (2D + MIP only)
- Registration not yet implemented (would require porting SimpleITK or a native Swift equivalent)

## License

Research/educational use.
