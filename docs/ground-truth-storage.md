# Soma Ground Truth storage

This document defines which files are allowed to participate in a new
accuracy cycle. The storage layout is deliberately split by provenance and
lifecycle; filenames alone are not a sufficient boundary.

## Runtime layout

```text
~/Library/Application Support/Soma/GroundTruth/
├── active/
│   ├── manifest.json
│   ├── human/
│   │   ├── gold.jsonl
│   │   ├── review_progress.jsonl
│   │   └── glossary.json
│   ├── evidence/
│   │   ├── decodes.jsonl
│   │   └── verdicts.jsonl
│   ├── experiments/
│   │   ├── stage7/
│   │   ├── stage8/
│   │   └── other/
│   └── layer1/
│       ├── state.json
│       ├── history.jsonl
│       ├── model_commands.json
│       └── batch-manifests/
└── archives/
    └── pre-structure-v1/
        ├── root/
        │   ├── gold.jsonl
        │   ├── decodes.jsonl
        │   ├── verdicts.jsonl
        │   ├── review_progress.jsonl
        │   ├── glossary.json
        │   └── experiments/
        └── layer1/
```

`active/` is the only namespace used by a new Layer-1 cycle. It starts empty
except for model command configuration. The existing state and artifacts are
moved byte-for-byte into `archives/pre-structure-v1/`; they remain available for
historical analysis but are not read by active code.

## Provenance rules

- `active/human/gold.jsonl` is the canonical human-verified reference. A row
  may be written only after all segments for a file have been reviewed. Filler
  words, repetitions, and spoken non-standard forms remain verbatim.
- `active/evidence/` contains observations and model verdicts, never reference
  truth. A decode or consensus verdict must not be promoted automatically.
- `active/experiments/` contains derived reports and samples. Stage-7 cleaned
  text is a projection, never a replacement for human gold. Stage-8 auto-gold
  remains a candidate with `source: stage8-consensus` and is never canonical
  human gold.
- `active/layer1/` contains the new model-major batch state and human segment
  decisions. Verified completed files are exported to `active/human/gold.jsonl`
  with `source: layer1-human`.
- `archives/` is historical. Old Stage-5/7/8 scripts default to the archived
  workspace so rerunning them cannot contaminate the active cycle.

## Current migration

Run a dry run first:

```bash
python3 Scripts/migrate_ground_truth_storage.py
```

Apply only when the move list is understood:

```bash
python3 Scripts/migrate_ground_truth_storage.py --apply
```

The migration is idempotent. It refuses to run if an active directory already
contains files, and it does not rewrite JSONL contents. Existing Layer-1
`model_commands.json` is copied into the new active configuration; old Layer-1
state, manifests, history, and results stay in the archive.

## Code ownership

- Python path constants: `Scripts/ground_truth_paths.py`
- Swift path constants: `Soma/ViewModels/GroundTruthPaths.swift`
- migration: `Scripts/migrate_ground_truth_storage.py`
- old review runner: archived workspace
- new Layer-1 runner: `active/layer1/`
