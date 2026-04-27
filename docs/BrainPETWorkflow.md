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
