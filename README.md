# Tracer

Tracer is a native SwiftUI imaging workstation for macOS and iPadOS. It is
being built as a serious single-user PACS, PET/CT review station, AI
segmentation lab, labeling platform, and nuclear medicine research tool.

The goal is direct: make a local workstation that feels closer to commercial
systems such as MIM, Visage, and Sectra than to a demo app, while preserving
the openness and hackability of research platforms such as 3D Slicer.

Tracer is research software. It is not FDA-cleared, CE-marked, or intended for
diagnostic clinical use without independent validation.

---

## Current Status

The default branch contains the core workstation:

- DICOM and NIfTI loading with orientation-aware geometry
- PACS-style worklist and study browser
- multi-viewport MPR review with customizable hanging protocols
- PET/CT fusion, PET MIP, CT windows, PET colormaps, SUV controls
- segmentation and labeling tools with undo/redo
- PET and CT volumetry foundations
- SUV ROI and PET lesion metrics
- nnU-Net, MONAI Label, MedSAM2, and assistant-driven segmentation routing
- cohort processing, classification infrastructure, and remote/DGX execution
- native exports for label maps, annotations, landmarks, meshes, and reports

Several large research modules live on feature branches so they can evolve
without destabilizing the main viewer:

| Branch | Focus |
|---|---|
| `feature/segmentation-fusion` | Migration path from the legacy PET Segmentator app into Tracer, including external LesionTracer model adoption |
| `feature/pet-attenuation-correction` | PET attenuation-correction workflow experiments |
| `feature/recon-pet-spect` | PET/SPECT reconstruction foundation from raw sinogram-style inputs |
| `feature/synthetic-ct-from-pet` | Synthetic CT generation from PET-derived features |
| `feature/dynamic-nm-workflow` | Dynamic PET / nuclear medicine visualization and time-activity workflows |
| `feature/lu177-dosimetry` | Lu-177 SPECT/CT dosimetry, absorbed dose maps, timepoint curves, and cycle planning |

---

## Why Tracer Exists

Modern imaging work often spans multiple tools:

- a PACS viewer for review
- a research viewer for labeling
- 3D Slicer for segmentation utilities
- command-line nnU-Net or MONAI for inference
- spreadsheets or scripts for SUV/TMTV/TLG
- separate code for cohort processing and model training
- separate dosimetry, reconstruction, or synthetic CT experiments

Tracer is intended to collapse that workflow into one local application. A
single user should be able to open a PET/CT study, review it in multiple
linked viewports, fuse PET and CT, draw or generate labels, measure SUV and
volumes, run segmentation models, export masks, process cohorts, and build
research datasets without constantly switching tools.

---

## Imaging Workstation

### Viewer Layouts

Tracer supports PACS-style viewing rather than a fixed demo layout.

- axial, sagittal, and coronal MPR
- PET-only, CT-only, fused PET/CT, and PET MIP panes
- customizable hanging protocols
- single-pane, 2-up, 2x2, and larger viewport grids
- viewport-level modality, plane, colormap, fusion, and MIP settings
- linked zoom and pan controls
- cross-reference behavior between orthogonal planes
- focus mode for contouring and high-density review

The viewer is designed around the idea that the worklist and the viewing
windows are separate concerns: the operator chooses a study in the worklist,
then reviews it in a configurable viewport layout.

### Display Controls

- modality-aware CT window presets
- PET SUV min/max range controls
- PET colormap selection per viewport
- PET MIP inversion
- fusion opacity control
- fusion on/off control
- PET-over-CT and CT-over-PET visualization clarity
- anterior/posterior and right/left display correction controls
- histogram-based auto window/level

### GPU Rendering

Tracer includes Metal-backed rendering infrastructure for fast image display
and volume rendering. The long-term target is full GPU acceleration for:

- 2D slice rendering
- label overlays
- PET MIP rendering
- 3D volume rendering
- fused PET/CT rendering
- interactive contouring responsiveness during heavy background work

---

## PACS and Worklist

Tracer is not just a file opener. It includes a mini-PACS layer intended for
large local datasets.

### Indexing

- recursive directory indexing
- DICOM metadata extraction
- study, series, patient, modality, and date grouping
- duplicate detection by stable identity
- cancellation support during large scans
- searchable indexed snapshots
- support for directories with thousands of studies

### Worklist

- study-level grouping
- series-level selection
- filters and search
- recently opened studies
- separation between browsing and viewing
- foundation for cohort selection and batch jobs

The intended use case is a single investigator or lab workstation with large
local folders, not a multi-user hospital PACS server.

---

## DICOM, NIfTI, and Geometry

Tracer treats geometry as a first-class requirement because segmentation,
fusion, RTSTRUCT, registration, and SUV measurements all fail quietly when
geometry is wrong.

### DICOM

- Explicit VR Little Endian and Implicit VR Little Endian support
- compressed transfer syntax rejection instead of silent blank rendering
- series sorting using image orientation and slice normal
- slice spacing derived from patient-space positions
- mixed-dimension protection
- SOP/series duplicate handling
- PET SUV metadata support where available

### NIfTI

- `.nii` and `.nii.gz`
- sform/qform-aware world geometry
- spacing, origin, and direction preservation
- label-map import/export

### Additional Formats

Read and write:

- NIfTI label maps
- NRRD / `.seg.nrrd`
- native `.dvlabels` packages
- JSON annotations
- CSV landmarks
- STL and OBJ meshes from label maps

Read:

- DICOM RTSTRUCT

---

## PET/CT and Nuclear Medicine

Tracer has a PET-first workflow because PET/CT labeling and quantification are
central goals of the project.

### PET/CT Fusion

- CT and PET pairing
- PET-to-CT fusion display
- SUV-scaled PET inputs for AI models
- PET MIP viewport
- per-window PET colormap
- per-window SUV range
- fusion opacity
- linked MPR review

### SUV Measurement

Current measurement and quantification foundations include:

- spherical PET SUV ROI
- SUVmax
- SUVmean
- SUVpeak foundation
- metabolic tumor volume
- total lesion glycolysis
- connected-component lesion breakdown
- SUV threshold segmentation
- percent-of-SUVmax segmentation
- SUV gradient-edge segmentation
- volume in mL using voxel spacing

### PET Volumetry

PET segmentation and measurement tools include:

- fixed SUV threshold
- percent of local or lesion SUVmax
- gradient-edge growth
- connected-component filtering
- lesion island cleanup
- TMTV / TLG reporting
- physiological uptake filtering using anatomy masks

### CT Volumetry

CT volumetry foundations include:

- HU range segmentation
- connected-component cleanup
- organ or lesion class assignment
- label-map based volume reporting
- mesh export for 3D inspection

---

## Segmentation and Labeling

Tracer is intended to replace a separate PET Segmentator workflow and become a
large-scale labeling workstation for thousands of PET/CT studies.

### Manual Labeling

- multi-class 3D label maps
- brush and eraser
- undo/redo
- reset editable changes
- island cleanup
- grow/shrink morphology
- level-set style segmentation
- SUV-aware region growing
- gradient-aware PET segmentation
- label presets
- class categories and colors
- exportable label packages

### Label Presets

Tracer includes built-in taxonomies for:

- AutoPET lesion labels
- TotalSegmentator-style organs
- Medical Segmentation Decathlon classes
- AMOS-style abdominal labels
- BraTS brain tumor labels
- radiotherapy target labels
- head and neck organs at risk
- thoracic organs at risk
- abdominal organs at risk
- pelvic organs at risk
- ITK-SNAP-inspired brain, cardiac, knee, liver, spine, and breast presets

### AI Segmentation

Tracer can route segmentation tasks to multiple backends:

| Engine | Role |
|---|---|
| Assistant Chat | Natural-language interpretation and task routing |
| Segmentation RAG | Chooses labels and candidate models from disease/process/body-region language |
| nnU-Net v2 | Local Python subprocess inference or CoreML inference |
| MONAI Label | Server-backed interactive and active-learning segmentation |
| MedSAM2 | Box-prompt refinement |
| PET Engine | AutoPET, LesionTracer, LesionLocator, TMTV, and PET-specific cleanup |
| DGX Remote | SSH execution for heavy models on a remote workstation |

### PET Segmentator Migration

The `feature/segmentation-fusion` branch adds a bridge from the old PET
Segmentator project into Tracer:

- discovers the existing LesionTracer model folder
- registers it without copying several gigabytes of weights
- uses nnU-Net model-folder inference
- preserves PET SUV channel scaling
- exposes fast, accurate, and max-sensitivity segmentation profiles
- adds SUV-attention connected-component cleanup

The end goal is to retire the standalone Segmentator app and make Tracer the
single home for PET/CT segmentation, editing, measurement, and export.

---

## Assistant and Automation

Tracer includes an assistant layer designed to make imaging operations
addressable by natural language.

Examples of intended commands:

- "segment FDG-avid lymphoma"
- "use LesionTracer for whole-body PET disease"
- "make a liver lesion label"
- "change PET SUV range to 0 to 12"
- "turn fusion off"
- "switch this viewport to coronal"
- "measure a spherical SUV ROI here"

The assistant is designed to work with local CLI providers such as ChatGPT CLI
or Claude CLI, while keeping image operations inside Tracer. Heavy inference is
guarded so repeated submissions do not launch overlapping model runs against
the same label state.

---

## Cohort Processing

Tracer includes infrastructure for processing cohorts rather than only one
study at a time.

- batch study loading
- PET/CT channel preparation
- SUV-scaled PET model inputs
- nnU-Net inference jobs
- classification sidecar output
- cohort checkpointing
- CSV export
- study-level result folders
- configurable classifier artifacts
- remote execution support

This is aimed at research workflows such as labeling or measuring thousands of
PET/CT studies.

---

## Classification and Model Management

Tracer includes a model registry so local, downloaded, and remote artifacts can
be tracked consistently.

Supported artifact types include:

- CoreML packages
- nnU-Net datasets and trained-model folders
- MONAI bundles
- GGUF language model weights
- tree-model JSON files
- Python classifier scripts
- remote DGX artifacts

The classification layer is positioned as research/training infrastructure,
not a clinical diagnosis engine. It supports real model artifacts and avoids
presenting placeholder/demo predictions as validated clinical outputs.

---

## Active Research Modules

These modules are being developed on separate branches.

### PET and SPECT Reconstruction

Branch: `feature/recon-pet-spect`

Target capabilities:

- raw PET/SPECT data staging
- sinogram-style input representation
- reconstruction job model
- iterative reconstruction hooks
- attenuation/scatter/randoms correction placeholders
- output as Tracer-native `ImageVolume`

### Synthetic CT from PET

Branch: `feature/synthetic-ct-from-pet`

Target capabilities:

- generate CT-like volumes from PET-derived features
- support attenuation-correction research workflows
- preserve geometry for PET/CT fusion and downstream segmentation
- keep synthetic outputs clearly labeled as generated/research images

### Dynamic PET and Nuclear Medicine

Branch: `feature/dynamic-nm-workflow`

Target capabilities:

- time-frame aware volumes
- dynamic series navigation
- time-activity curve extraction
- ROI-based kinetic summaries
- dynamic PET and general nuclear medicine study review

### Lu-177 Dosimetry

Branch: `feature/lu177-dosimetry`

Target capabilities:

- Lu-177 SPECT/CT dosimetry workflow
- single-timepoint and multi-timepoint analysis
- time-activity curves
- absorbed dose maps
- local deposition dose calculation
- Monte Carlo dose transport foundation
- cycle-level dose accumulation for 4-cycle and 6-cycle therapy planning
- quantitative QA checks

---

## Architecture

Tracer is written in Swift and SwiftUI with Apple-native frameworks.

- SwiftUI for UI
- SwiftData for local PACS metadata
- Metal and MetalKit for rendering
- CoreML for on-device model execution
- URLSession for MONAI and deploy clients
- Compression for `.nii.gz`
- Foundation and simd for geometry and IO

Directory overview:

```text
Sources/
├── Tracer/
│   ├── App/                # App scene and commands
│   ├── Classification/     # Radiomics, CoreML, MedGemma, subprocess classifiers
│   ├── Cohort/             # Batch jobs, checkpoints, exports, study results
│   ├── IO/                 # DICOM, NIfTI, RTSTRUCT, label IO, PACS indexing
│   ├── ModelManagement/    # Local model registry, downloads, bindings
│   ├── Models/             # ImageVolume, LabelMap, hanging protocols, SUV, RAG
│   ├── Networking/         # MONAI Label, MONAI Deploy, nnU-Net, MedSAM2
│   ├── Processing/         # PET/CT segmentation, quantification, morphology, meshes
│   ├── Remote/             # DGX Spark SSH execution
│   ├── Rendering/          # Pixel rendering, labels, colormaps, Metal volume renderer
│   ├── ViewModels/         # Viewer, labeling, assistant, engines, classification
│   └── Views/              # Workstation panels and SwiftUI views
└── TracerApp/
    └── main.swift
```

---

## Building

### Command Line

```bash
swift build
swift run TracerApp
swift test
./build_app.sh
./build_app.sh install
```

### Xcode

```bash
open Package.swift
```

Then select `TracerApp` and run on macOS or an iPad simulator.

---

## Git Workflow

The default branch is `main`.

Large subsystems are developed on feature branches because reconstruction,
synthetic CT, dosimetry, dynamic imaging, attenuation correction, and
segmentation migration are each large enough to deserve independent review.

Recommended workflow:

```bash
git fetch origin
git checkout main
git pull
git checkout feature/segmentation-fusion
```

Merge feature branches into `main` only after the specific module builds,
tests, and has a clear user-facing workflow.

---

## Safety and Validation

Tracer should be treated as research software.

Important safety principles:

- unsupported DICOM transfer syntaxes should fail clearly
- world geometry must be preserved for fusion, labels, registration, and dose
- PET SUV scaling must be explicit and volume-aware
- heavy inference should run without freezing the UI
- segmentation and classification outputs require human review
- synthetic CT and reconstructed images must be labeled as generated/research
- dosimetry outputs require independent validation before clinical use

---

## Attribution

Tracer integrates with or references workflows inspired by several open
research ecosystems. Each model and dataset retains its own license.

Notable model families and tools:

- nnU-Net v2
- AutoPET II / III / IV
- LesionTracer
- MedSAM2
- MONAI Label
- MONAI Deploy
- TotalSegmentator
- 3D Slicer / ITK-SNAP-style label workflows

Model licenses vary. In particular, LesionTracer weights are CC-BY-4.0, the
nnU-Net core code is Apache-2.0, MedSAM2 is Apache-2.0, TotalSegmentator core
is Apache-2.0, and some imaging datasets are non-commercial or research-only.

---

## Current Direction

Tracer is moving toward becoming a complete local imaging research platform:

1. PACS-grade single-user study management
2. high-quality PET/CT fusion and MPR review
3. complete segmentation and labeling pipeline
4. SUV and volume measurement tools that are reliable enough for large cohorts
5. AI-assisted model and label selection
6. replacement of the legacy PET Segmentator app
7. dynamic nuclear medicine and dosimetry workflows
8. reconstruction and synthetic CT research modules

The north star is one app where an imaging researcher can review, segment,
measure, train, validate, and export without leaving the workstation.
