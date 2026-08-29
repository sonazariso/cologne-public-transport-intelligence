#!/usr/bin/env python3
"""Profile a VRS static GTFS directory and its initial Cologne scope."""

from __future__ import annotations

import argparse
import csv
from collections import Counter
from pathlib import Path


REQUIRED_FILES = (
    "agency.txt",
    "calendar.txt",
    "calendar_dates.txt",
    "feed_info.txt",
    "frequencies.txt",
    "routes.txt",
    "shapes.txt",
    "stop_times.txt",
    "stops.txt",
    "transfers.txt",
    "trips.txt",
)


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as source:
        return list(csv.DictReader(source))


def count_data_rows(path: Path) -> int:
    with path.open("rb") as source:
        return max(sum(chunk.count(b"\n") for chunk in iter(lambda: source.read(1024 * 1024), b"")) - 1, 0)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("gtfs_dir", type=Path, help="Directory containing extracted GTFS text files")
    parser.add_argument("--cologne-prefix", default="de:05315:")
    args = parser.parse_args()

    missing = [name for name in REQUIRED_FILES if not (args.gtfs_dir / name).is_file()]
    if missing:
        raise SystemExit(f"Missing required GTFS files: {', '.join(missing)}")

    stops = read_rows(args.gtfs_dir / "stops.txt")
    routes = read_rows(args.gtfs_dir / "routes.txt")
    trips = read_rows(args.gtfs_dir / "trips.txt")

    cologne_stop_ids = {
        row["stop_id"] for row in stops if row["stop_id"].startswith(args.cologne_prefix)
    }
    trip_to_route = {row["trip_id"]: row["route_id"] for row in trips}
    route_to_type = {row["route_id"]: row["route_type"] for row in routes}

    cologne_trips: set[str] = set()
    used_cologne_stops: set[str] = set()
    cologne_stop_times = 0
    with (args.gtfs_dir / "stop_times.txt").open(encoding="utf-8-sig", newline="") as source:
        for row in csv.DictReader(source):
            if row["stop_id"] in cologne_stop_ids:
                cologne_trips.add(row["trip_id"])
                used_cologne_stops.add(row["stop_id"])
                cologne_stop_times += 1

    cologne_routes = {
        trip_to_route[trip_id] for trip_id in cologne_trips if trip_id in trip_to_route
    }
    routes_by_type = Counter(
        route_to_type[route_id] for route_id in cologne_routes if route_id in route_to_type
    )
    trips_by_type = Counter(
        route_to_type[trip_to_route[trip_id]]
        for trip_id in cologne_trips
        if trip_id in trip_to_route and trip_to_route[trip_id] in route_to_type
    )

    print("GTFS file data rows")
    for name in REQUIRED_FILES:
        print(f"  {name}: {count_data_rows(args.gtfs_dir / name):,}")

    print("\nInitial Cologne scope")
    print(f"  Stops: {len(used_cologne_stops):,}")
    print(f"  Routes: {len(cologne_routes):,}")
    print(f"  Trips: {len(cologne_trips):,}")
    print(f"  Stop times: {cologne_stop_times:,}")

    print("\nRoute types (type, routes, trips)")
    for route_type in sorted(routes_by_type, key=int):
        print(f"  {route_type}: {routes_by_type[route_type]:,}, {trips_by_type[route_type]:,}")


if __name__ == "__main__":
    main()
