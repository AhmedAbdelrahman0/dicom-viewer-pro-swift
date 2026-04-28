# Brain PET Workflow

Tracer's Brain PET panel is atlas-driven. The active label map is treated as
the regional brain atlas, and the active PET volume is sampled region by region.

## Supported analyses

- FDG: regional uptake, reference-normalized SUVR, optional normal-database
  z-scores, and low-uptake region listing.
- Amyloid: cortical target SUVR and Centiloid conversion through a configurable
  linear calibration.
- Tau: regional SUVR and adjustable Braak-style staging threshold.

## Normal database CSV

Import a CSV from the Brain PET panel. Required columns:

```csv
region,labelID,meanSUVR,sdSUVR,n,ageMin,ageMax
Left temporal,1,0.95,0.10,40,55,85
Right temporal,2,0.96,0.11,40,55,85
```

Required:

- `region`
- `meanSUVR`
- `sdSUVR`

Optional:

- `labelID`
- `n`
- `ageMin`
- `ageMax`

If `labelID` is present, Tracer matches normals by label value. Otherwise it
matches by normalized region name.

## Recommended normal-data sources

- GAAIN Centiloid Project: amyloid Centiloid reference data and standard VOIs.
- ADNI PET Core / UC Berkeley PET summaries: FDG, amyloid, and tau regional
  SUVR, Centiloid, QC, and metadata tables.
- OASIS-3: aging and Alzheimer cohort with PiB, AV45, FDG, and PET Unified
  Pipeline regional outputs.
- NEUROSTAT / 3D-SSP: FDG z-score surface projection workflow and test normal
  databases.

Clinical use requires local validation of the atlas, reference region,
resolution smoothing, tracer timing, scanner harmonization, and threshold
selection.

## GAAIN Spark reference build

The Brain PET panel includes a **GAAIN reference builder** disclosure group.
Use **Scan GAAIN** after downloading the public GAAIN Centiloid archives into:

```text
~/Library/Application Support/Tracer/NormalDatabases/InternetDownloads/GAAIN-Centiloid
```

Use **Export Spark Job** to create:

```text
~/Library/Application Support/Tracer/ReferenceBuilds/GAAIN-Centiloid
```

The package contains:

- `gaain_reference_build_plan.json`: a reproducible tracer-by-tracer compute
  plan for PiB, florbetapir/Amyvid, florbetaben, flutemetamol, NAV4694, and FDG
  assets when present.
- `gaain_reference_build.py`: a self-contained Python worker for local or DGX
  Spark execution.
- `run_gaain_reference_build.sh`: a direct launch script.

The first compute stage extracts archives, inventories NIfTI imaging, applies
standard VOIs when PET and VOI grids already match, and writes Tracer-compatible
normal CSVs plus per-tracer QC files. If a PET scan needs registration,
deformable alignment, DICOM conversion, or missing dependencies, the worker
records that as QC rather than silently producing a bad normal database.

If DGX Spark is enabled in Settings, **Run on Spark** performs the remote
workflow directly from Tracer:

1. Exports the local package.
2. Uploads package files to the configured Spark workdir.
3. Syncs any missing GAAIN archives into
   `~/tracer-remote/gaain-centiloid-data` by default.
4. Runs the Python worker on Spark and streams logs to the Job Center.
5. Pulls `results.tgz` back into
   `~/Library/Application Support/Tracer/ReferenceBuilds/GAAIN-Centiloid/remote-results`.

The first run can upload roughly 20 GB if Spark does not already have the
archives. Later runs skip files whose remote byte counts match the local
manifest.
