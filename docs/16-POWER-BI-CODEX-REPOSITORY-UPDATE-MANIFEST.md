# Power BI Codex Workflow — Repository Update Manifest

**Updated:** 2026-09-15

This documentation update records the Chat 06 migration to PBIP/TMDL/PBIR + Codex and prepares the repository for the remaining Power BI work.

## Files added

- `docs/14-POWER-BI-PBIP-CODEX-WORKFLOW.md`
- `docs/15-POWER-BI-CHAT06-CODEX-MIGRATION-HANDOFF.md`
- `docs/16-POWER-BI-CODEX-REPOSITORY-UPDATE-MANIFEST.md`
- `prompts/powerbi-codex/README.md`
- `prompts/powerbi-codex/01-read-only-semantic-model-audit.md`
- `prompts/powerbi-codex/02-safe-tmdl-edit-template.md`
- `prompts/powerbi-codex/03-read-only-report-audit.md`
- `prompts/powerbi-codex/04-safe-pbir-edit-template.md`

## Files updated

- `.gitignore`
- `README.md`
- `docs/08-POWER-BI-STATIC-BASELINE-BUILD-GUIDE.md`
- `docs/13-POWER-BI-DAX-MEASURE-LAYER.md`
- `docs/LOCAL-DOCS-STATUS.md`
- `powerbi/README.md`
- `powerbi/theme/README.md`

## Git ignore policy added

```gitignore
# Power BI Project local state
**/.pbi/localSettings.json
**/.pbi/cache.abf

# Power BI Desktop binary files
/powerbi/*.pbix
```

## Power BI local project files not recreated in this archive

The user's active local repository contains the PBIP project created during Chat 06:

```text
powerbi/CologneTransitIntelligence.pbip
powerbi/CologneTransitIntelligence.Report/
powerbi/CologneTransitIntelligence.SemanticModel/
```

These exact files were created locally after the source ZIP used for this documentation build had already been uploaded. They are therefore **not reconstructed or fabricated** in this archive.

When applying this update to the active local repository, preserve the real local PBIP/TMDL/PBIR files. Merge the documentation/source updates; do not replace the active Power BI project with an older snapshot.

## Next task

Continue Chat 06 with PBIR/Codex and finalize the KPI Card design standard on `00 - Template`.
