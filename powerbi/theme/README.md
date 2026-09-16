# Power BI Theme

Current human-maintained theme source:

```text
cologne-transit-intelligence-theme.json
```

**Reviewed:** 2026-09-15 during Chat 06 — Design System & Theme.

The theme was successfully imported into the active Power BI report. It remains the design foundation for the portfolio report.

The Power BI project now uses PBIP/PBIR, so Power BI also stores a registered copy of the theme under the report project's `StaticResources/RegisteredResources/` area. Treat the repository file in this directory as the intentional design asset; treat the registered resource copy as Power BI-managed report content unless a controlled PBIR/theme migration specifically requires otherwise.

Current Chat 06 design baseline:

- canvas: 1280 × 720 / 16:9;
- template page: `00 - Template`;
- title: X 32 / Y 24 / W 1216 / H 58;
- subtitle: X 32 / Y 90 / W 1216 / H 36;
- first KPI row starts at Y 150;
- sample KPI card: X 32 / Y 150 / W 230 / H 110;
- full numeric display is enabled so count KPIs are not automatically abbreviated to `K`;
- `00 - Template` is the approved Design System / Component Library reference used by the final report pages.

Any future color/formatting change must preserve semantic caution: do not use `good` / `neutral` / `bad` colors to imply On-Time / delay-severity categories unless an explicit, documented business threshold has first been approved.

The code-first report-authoring workflow is documented in:

```text
../../docs/14-POWER-BI-PBIP-CODEX-WORKFLOW.md
```
