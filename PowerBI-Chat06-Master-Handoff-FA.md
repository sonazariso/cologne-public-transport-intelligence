# Handoff برای Master Chat — Power BI Chat 06 / Codex + PBIP Migration

**تاریخ:** 2026-09-15  
**وضعیت:** مهاجرت workflow و تست زیرساخت کامل شد — خود Design System & Theme هنوز در حال انجام است.

## 1. تغییر مهم معماری Power BI

Power BI دیگر با رویکرد PBIX-only ادامه داده نمی‌شود.

فایل محلی فعال به Power BI Project تبدیل شد:

```text
powerbi/CologneTransitIntelligence.pbip
powerbi/CologneTransitIntelligence.Report/
powerbi/CologneTransitIntelligence.SemanticModel/
```

از این به بعد Source Authoring اصلی برای Power BI:

```text
PBIP + TMDL + PBIR
```

است و VS Code + Codex روی macOS برای بخش عمده authoring استفاده می‌شود.

Power BI Desktop داخل Windows VM حذف نشده و همچنان برای این موارد لازم است:

- Import Refresh از SQL Server؛
- Rendering واقعی Visualها؛
- بررسی layout و text clipping؛
- Slicer / Interaction / Drill-through / Bookmark / Tooltip validation؛
- باز کردن و validate کردن تغییرات external؛
- Save و final QA / Publish workflow.

Workflow جدید:

```text
VS Code + Codex (Mac)
    -> TMDL / PBIR / Theme / DAX / SQL / Docs
    -> Git diff
    -> Power BI Desktop (Windows VM)
    -> Render / Refresh / Interaction QA
    -> Save
    -> Git diff / Commit
```

## 2. ابزارهایی که نصب/فعال شدند

روی Mac:

- VS Code
- Codex
- Git
- SQL Server extension (از قبل موجود و به SQL Server VM متصل)
- Microsoft TMDL extension با ID:

```text
analysis-services.TMDL
```

در Power BI Desktop این Preview Features فعال شدند:

- `Power BI Project (.pbip) save option`
- `Store semantic model using TMDL format`
- `Store reports using enhanced metadata format (PBIR)`

گزینه PBIR مخصوص PBIX برای این مهاجرت لازم نبود، چون پروژه به PBIP تبدیل شد.

## 3. Git policy جدید

`.gitignore` باید شامل این موارد باشد:

```gitignore
# Power BI Project local state
**/.pbi/localSettings.json
**/.pbi/cache.abf

# Power BI Desktop binary files
/powerbi/*.pbix
```

یعنی:

- `.pbip` باید Track شود.
- `.Report/` باید Track شود.
- `.SemanticModel/` باید Track شود.
- PBIX فقط backup باینری محلی است و Source of Truth نیست.
- `cache.abf` و `localSettings.json` نباید commit شوند.
- کل `.pbi` را blanket-ignore نمی‌کنیم.

Baseline commit تأییدشده:

```text
0044919 Add Power BI project source format
```

## 4. TMDL audit با Codex

Codex در حالت read-only مدل Semantic را بررسی کرد.

نتیجه:

- 33 table در TMDL export؛
- Business dimensions:
  - `ActiveDate`
  - `Mode`
  - `ParentStation`
  - `Route`
  - `StopPosition`
- Fact/analytics tables مهم:
  - `DailySchedule`
  - `RT_CollectorRunHealth`
  - `RT_DataQualityCoverage`
  - `RT_ConsolidationQuality`
  - `RT_ReliabilityOutcome`
- helper/disconnected:
  - `NetworkKPI`
  - `RT_ReliabilityByDimension`
  - `_Measures`
- 19 عدد `LocalDateTable_*` + template در export وجود دارد؛ در این Chat به آنها دست زده نشد و defect تلقی نشدند.
- 27 relationship در exported TMDL شامل local-date relationships؛
- Bidirectional relationship پیدا نشد؛
- active ambiguous filter path پیدا نشد؛
- `_Measures` هیچ relationship ندارد؛
- 68 explicit measure در `_Measures`؛
- Display Folders:
  - `01 Static Schedule` — 9
  - `02 Network Baseline` — 12
  - `03 Realtime Reliability` — 8
  - `04 Evidence` — 8
  - `05 Consolidation` — 5
  - `06 Data Quality` — 17
  - `07 Collector Health` — 9

## 5. تست واقعی Codex -> TMDL -> Power BI

اولین external edit فقط metadata بود.

برای measure زیر:

```text
Observed Matched Services
```

این description با Codex در `_Measures.tmdl` اضافه شد:

```text
Count of matched operational stop outcomes available for validated realtime reliability analysis.
```

Power BI Desktop فایل PBIP را بدون خطا باز کرد و Description دیده شد.

بعد Save Round-trip انجام شد و Git diff نشان داد Power BI هیچ DAX، formatString، displayFolder یا lineageTag را بی‌دلیل تغییر نداده است.

Power BI فقط `diagramLayout.json` را برای scroll position تغییر داد. این تغییر restore شد.

قاعده جدید:

```text
diagramLayout.json = Desktop-owned UI layout metadata
```

Codex نباید عمداً آن را ویرایش کند.

## 6. PBIR audit با Codex

Codex Report Project را read-only بررسی کرد.

صفحات موجود در زمان audit:

- Page 1 — 1280x720 — 7 visuals
- Page 2 — 1280x720 — 4 visuals
- Page 3 — 1280x720 — 4 visuals
- `00 - Template` — 1280x720 — 3 visuals

همه در حالت `FitToPage` بودند.

### `00 - Template`

Page identifier:

```text
3cdff3efc36ad5b16990
```

Visualهای فعلی:

**Page Title**

```text
Identifier: 45b26de4d7002c56ad33
X=32 Y=24 W=1216 H=58
```

**Subtitle**

```text
Identifier: f70e8350c1013d1d530a
X=32 Y=90 W=1216 H=36
```

**Observed Matched Services Card**

```text
Identifier: d12f9c4e72d9b98cb551
X=32 Y=150 W=230 H=110
```

## 7. تست واقعی Codex -> PBIR -> Power BI

Codex فقط متن Subtitle را تغییر داد.

قبل:

```text
Short page description or scope
```

بعد:

```text
Layout and visual styling reference for all report pages
```

فقط یک `visual.json` تغییر کرد.

Power BI Desktop PBIP را بدون خطا باز کرد و متن جدید با همان layout نمایش داده شد.

Save Round-trip نیز تمیز بود و Power BI هیچ PBIR metadata اضافی را rewrite نکرد.

بنابراین هر دو مسیر زیر PASS شدند:

```text
Codex -> TMDL -> Power BI Desktop -> Save -> Git diff
Codex -> PBIR -> Power BI Desktop -> Save -> Git diff
```

## 8. Design System که تا اینجا ساخته شد

Theme زیر با موفقیت import شد:

```text
powerbi/theme/cologne-transit-intelligence-theme.json
```

Template:

```text
00 - Template
Canvas: 1280 x 720 / 16:9
```

Layout استاندارد فعلی:

```text
Title:    X=32 Y=24  W=1216 H=58
Subtitle: X=32 Y=90  W=1216 H=36
KPI row:  Y=150
```

Sample KPI:

```text
Measure: [Observed Matched Services]
X=32 Y=150 W=230 H=110
```

Power BI setting مربوط به Display Units طوری تنظیم شد که countها به صورت K/M خلاصه نشوند و مقدار کامل نشان داده شود.

**KPI Card styling هنوز نهایی نشده است.**

## 9. وضعیت Chat 06

بخش زیر کامل شده:

```text
Power BI authoring workflow migration / validation = COMPLETE
```

ولی:

```text
Chat 06 — Design System & Theme = IN PROGRESS
```

مرحله بعد دقیقاً این است:

> با روش جدید PBIR + Codex، KPI Card pattern را روی `00 - Template` نهایی کنیم (typography, padding, border, background, label behavior)، در Power BI Desktop render/validate کنیم و بعد pattern تأییدشده را برای صفحات دیگر reuse کنیم.

## 10. قوانین ادامه کار

برای هر تغییر Power BI از این workflow استفاده شود:

1. Power BI Desktop را Save کن.
2. برای external structural edit بهتر است Desktop بسته باشد.
3. `git status` را بررسی کن.
4. Codex را به یک فایل/object/visual دقیق محدود کن.
5. از Codex بخواه فقط Git diff تغییر را نشان دهد.
6. `git diff` را قبل از Power BI review کن.
7. PBIP را در Power BI Desktop باز کن.
8. rendering و رفتار واقعی را validate کن.
9. Save کن.
10. دوباره Git diff را چک کن.
11. تغییرات UI-noise ناخواسته را restore کن.
12. فقط تغییر منطقی validated را commit کن.

Codex نباید بی‌دلیل این فایل‌ها را ویرایش کند:

- `.pbi/cache.abf`
- `.pbi/localSettings.json`
- `diagramLayout.json`
- PBIX binary
- generated base-theme resources

## 11. Semantic guardrails بدون تغییر باقی ماندند

- فقط `Observed Estimated Delay`، نه confirmed `Actual Delay`؛
- On-Time threshold خودسرانه ممنوع؛
- Situation Evidence به معنی causality نیست؛
- Platform `Unknown` برابر `Unchanged` نیست؛
- `StaticCoverageMissing` و `Unresolved` Data Quality states هستند؛
- Cancellation/Departure KPI بدون source validation ساخته نشود؛
- هفت realtime location فقط Sampling Panel هستند نه full Köln coverage؛
- Data Quality rate = summed numerator / summed denominator.

## 12. Repository documentation اضافه/آپدیت شد

فایل‌های مهم جدید:

```text
docs/14-POWER-BI-PBIP-CODEX-WORKFLOW.md
docs/15-POWER-BI-CHAT06-CODEX-MIGRATION-HANDOFF.md
docs/16-POWER-BI-CODEX-REPOSITORY-UPDATE-MANIFEST.md
prompts/powerbi-codex/
```

همچنین این فایل‌ها update شدند:

```text
.gitignore
README.md
powerbi/README.md
powerbi/theme/README.md
docs/08-POWER-BI-STATIC-BASELINE-BUILD-GUIDE.md
docs/13-POWER-BI-DAX-MEASURE-LAYER.md
docs/LOCAL-DOCS-STATUS.md
```

## 13. نکته مهم درباره ZIP تولیدشده

PBIP/TMDL/PBIR واقعی در repository محلی کاربر بعد از آخرین ZIP آپلودشده ایجاد شدند.

بنابراین ZIP مستندسازی ساخته‌شده در این Chat، تمام documentation و repository text updates را دارد ولی نمی‌تواند byteهای واقعی این فایل‌های local را بازسازی کند:

```text
powerbi/CologneTransitIntelligence.pbip
powerbi/CologneTransitIntelligence.Report/
powerbi/CologneTransitIntelligence.SemanticModel/
```

این فایل‌های local نباید با نسخه قدیمی جایگزین شوند.

برای ادامه پروژه، repository محلی فعلی کاربر که PBIP واقعی را دارد Source of Truth برای Power BI project files است.
