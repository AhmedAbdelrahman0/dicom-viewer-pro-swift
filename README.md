# Tracer

A native SwiftUI **AI-assisted imaging workstation** for **macOS 14+** and **iPadOS 17+**.

Tracer fuses DICOM/NIfTI rendering with local AI segmentation: load a study,
ask the assistant to *"segment the liver"* or *"contour FDG-avid disease on
PET/CT"*, and Tracer routes the request to the right engine — nnU-Net v2,
MONAI Label, the PET Engine, or MedSAM2 — runs the model offline, drops the
result into the active label map, and reports TMTV / TLG / SUV stats inline.

Radiologist-grade. Keyboard-driven. No cloud required.

---

## What's inside

### Imaging core
- **MPR views** — Axial, Sagittal, Coronal + 3D MIP / volume rendering (Metal)
- **Native parsers** — DICOM (Explicit / Implicit VR LE, uncompressed) and NIfTI
  (`.nii`, `.nii.gz` with in-process gzip), zero third-party dependencies
- **Mini-PACS** — Recursive folder indexer with SwiftData-backed metadata,
  worklist grouping, filters, and paged search. Cancellable mid-scan.
- **PET/CT fusion** with 9 colormaps
- **Window / Level** — Modality-aware presets + histogram auto-contrast

### Segmentation & labeling
- 3D label maps (UInt16 voxels) aligned to parent volume geometry
- Brush / Eraser, region growing, morphological ops (grow / shrink / islands)
- SUV threshold, 40%-SUVmax, SUV gradient-edge, region-competition level sets
  (reimplemented from Yushkevich 2006)
- Landmark-based rigid registration (SVD / Horn 1987) + label migration
- Undo / redo with 256 MB memory cap
- 27 built-in label presets: TotalSegmentator, AutoPET, BraTS, AMOS, MSD,
  RT Standard, PET focal, oncology clinical, H&N / thorax / abdomen / pelvic
  OARs, ITK-SNAP-style brain / cardiac / knee / liver / spine / breast

### AI engines (all offline)
| Engine | What it does |
|---|---|
| **Assistant Chat** | Natural-language → tool / preset / inference routing via the segmentation RAG |
| **MONAI Label** | REST client for `/info/`, `/infer/{model}`, `/activelearning`, `/datastore`, `/train`; scribbles-on-`/infer/` flow for DeepEdit |
| **nnU-Net v2** | Subprocess runner (`nnUNetv2_predict`) *and* on-device CoreML fallback with matching intensity normalization. 15-entry catalog: MSD tasks, KiTS23, AMOS22, BraTS, TotalSegmentator, AutoPET II/III/IV |
| **PET Engine** | AutoPET II (FDG baseline), **LesionTracer** (AutoPET III 2024 winner — FDG+PSMA), **LesionLocator** (AutoPET IV interactive), **MedSAM2** box-prompt refinement, **TMTV / TLG** quantification, physiological-uptake filter via TotalSegmentator |

### File format support
Read + write: `.dcm`, `.nii` / `.nii.gz`, `.nrrd`, `.seg.nrrd` (3D Slicer),
ITK-SNAP `.nii + .label.txt`, native `.dvlabels` packages,
JSON annotations (COCO/CVAT subset), CSV landmarks, STL / OBJ meshes
(multi-label marching cubes export).

Read: DICOM RTSTRUCT.

### Workflow tools
- MONAI Deploy Informatics Gateway client (STOW-RS push, ACR-DSI inference,
  C-ECHO, health dashboard)
- PET-specific statistics: voxel count, volume (mL), SUVmax/mean/peak, TLG,
  TMTV, connected-component breakdown
- Dice / IoU / HD-95 segmentation metrics (MONAI-compatible)

---

## Keyboard shortcuts (macOS)

| Shortcut | Action |
|---|---|
| `⌘O` | Open DICOM directory |
| `⌘N` | Open NIfTI file |
| `⌘R` | Auto Window / Level (histogram-based) |
| `⌘E` | Toggle Focus Mode (viewport-only) |
| `⌘⇧A` | Jump to Assistant Chat |
| `⌘⇧M` | Open MONAI Label panel |
| `⌘⇧N` | Open nnU-Net panel |
| `⌘⇧P` | Open PET Engine panel |

---

## Architecture

Pure Swift 5.9+ using **no third-party dependencies** — everything builds on
Apple's frameworks:

- **SwiftUI** — UI
- **SwiftData** — Mini-PACS metadata index
- **Metal / MetalKit** — volume rendering
- **CoreML** — on-device inference
- **CoreGraphics** — pixel rendering
- **Compression** — `.nii.gz` decompression
- **URLSession** — MONAI Label / Deploy REST clients

```
Sources/
├── Tracer/              # Library (reusable)
│   ├── App/             # @main app scene
│   ├── Models/          # ImageVolume, LabelMap, NNUnetCatalog, SegmentationRAG, …
│   ├── IO/              # DICOM, NIfTI (read/write), LabelIO, PACSDirectoryIndexer
│   ├── Networking/      # MONAILabelClient, MONAIDeployClient, NNUnetRunner,
│   │                    #   NNUnetCoreMLRunner, MedSAM2Runner
│   ├── Processing/      # LevelSet, PETSegmentation, PETQuantification,
│   │                    #   PhysiologicalUptakeFilter, MarchingCubes, MONAITransforms
│   ├── Rendering/       # Colormaps, PixelRenderer, LabelRenderer, MetalVolumeRenderer
│   ├── ViewModels/      # ViewerViewModel, LabelingViewModel, MONAILabelViewModel,
│   │                    #   NNUnetViewModel, PETEngineViewModel, ViewerAssistant
│   └── Views/           # ContentView, SliceView, StudyBrowserView, ControlsPanel,
│                        #   AssistantPanel, MONAILabelPanel, NNUnetPanel, PETEnginePanel
└── TracerApp/
    └── main.swift       # Executable entry
```

---

## Building

### Command line (macOS)

```bash
swift build                   # Build the library + app
swift run TracerApp           # Run on macOS
swift test                    # Run the 76-test suite
./build_app.sh                # Produce a signed-looking Tracer.app bundle
./build_app.sh install        # Also copy it to ~/Desktop
```

### Xcode (macOS + iPad)

```bash
open Package.swift
```

Then select the **TracerApp** scheme → pick *My Mac* or an iPad simulator → `⌘R`.

---

## License & attribution

Research/educational use.

Models wrapped by Tracer carry their own licenses — note especially:

- **nnU-Net core + AutoPET II / III code** — Apache-2.0
- **LesionTracer weights** — CC-BY-4.0 (cite Isensee et al., *"From FDG to
  PSMA: multi-tracer whole-body lesion segmentation with nnU-Net"*,
  arXiv:2409.09478)
- **MedSAM2** — Apache-2.0
- **TotalSegmentator core** — Apache-2.0
- **AutoPET imagery** — CC-BY-NC (inference/retraining OK; don't redistribute
  the images)
- **ITK-SNAP-inspired label presets** — re-authored independently; the ITK-SNAP
  project itself is GPL-3.0 and is *not* linked
