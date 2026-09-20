# Power BI M02 — Station Coverage & Performance

`M02 - Station Coverage & Performance` is the second management page. It
answers which monitored stations perform better or worse, how much realtime
activity was observed at each station, and how the monitored sampling panel
relates to the wider station network.

## Shared management behavior

M02 uses the existing management facts and measures:

- `ManagementComparableTrip` for overall trip and punctuality KPIs;
- `ManagementTripStation` for station-grain comparisons and the detail table;
- `ManagementMonitoredStation` for the seven monitored station names; and
- the shared `Delay Threshold (Minutes)` parameter.

The date slicer uses `ManagementDate`, a calculated date dimension sourced from
the refreshed management realtime population. It relates only to the three
management facts, so M02 and M01 use the same dynamic realtime date scope while
legacy `ActiveDate` behavior remains unchanged.

## Station metrics

The station charts and table use one consistent punctuality metric:

`Station On-Time % = Station On-Time Trips / Station Observed Realtime Trips`

The station detail table contains the monitored station, observed realtime
trips, on-time trips and percentage, delayed trips and percentage, and observed
stop positions. It exposes no internal identifiers or technical data-quality
fields.

`Station` means a monitored station/location. `Stop Position` means an
individual boarding/platform/stop position within that station scope. Multiple
stop positions can therefore exist inside one monitored station.

## Runtime validation

Power BI Desktop remains required for Import Refresh, rendering, slicer
interaction, and final visual QA. The source-level checks confirm that the
page is finite-height, all seven station categories are configured in the
station visuals, the management-date relationships are isolated from
`ActiveDate`, and all referenced measures exist in the semantic model.
