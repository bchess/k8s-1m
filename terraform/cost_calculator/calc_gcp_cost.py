#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025 Benjamin Chess
"""
Compute the hourly cost of the VMs described in a Terraform *.tfvars file.

Usage:
    python calc_gcp_cost.py example.tfvars
"""

import argparse
import pathlib
import re
import sys
from functools import lru_cache

import hcl2
import requests
from bs4 import BeautifulSoup
from tabulate import tabulate


def _region_from_zone(zone: str) -> str:
    # "us-central1-c" → "us-central1"
    return "-".join(zone.split("-")[:-1])


@lru_cache(maxsize=None)
def _fetch_price(machine_type: str, region: str, preemptible: bool) -> float:
    """
    Scrape https://gcloud-compute.com/<machine_type>[ -lssd].html and
    return the hourly price for the given region.
    """
    urls = [
        f"https://gcloud-compute.com/{machine_type}.html",
        f"https://gcloud-compute.com/{machine_type}-lssd.html",
    ]

    html = None
    for url in urls:
        try:
            resp = requests.get(url, timeout=15)
            resp.raise_for_status()
            html = resp.text
            break
        except requests.RequestException:
            continue

    if html is None:
        raise RuntimeError(f"Couldn’t fetch pricing page for {machine_type}")

    soup = BeautifulSoup(html, "html.parser")

    # The “Price per Region” table always has the Region code in the first <td>
    target_row = None
    for tr in soup.select("table tr"):
        tds = tr.find_all("td")
        if tds and tds[0].get_text(strip=True) == region:
            target_row = [td.get_text(strip=True) for td in tds]
            break

    if not target_row or len(target_row) < 6:
        raise ValueError(
            f"Region {region} not found in pricing table for {machine_type}"
        )

    # Row schema: Region | Location | #Zones | #Platf. | Hour | Spot | …
    price_hour = target_row[5] if preemptible else target_row[4]
    return float(price_hour)


def _parse_tfvars(path: pathlib.Path):
    """
    Return a list of resource dicts with keys:
        name, instance_type, region, replicas, preemptible
    """
    with path.open("r") as fp:
        data = hcl2.load(fp)

    # Capture any top-level “…_replicas = N” declarations
    replica_map = {
        key[: -len("_replicas")]: value
        for key, value in data.items()
        if key.endswith("_replicas")
    }

    resources = []

    for key, value in data.items():
        # Single resource blocks --------
        if key.endswith("_cloud_details") and isinstance(value, dict):
            res_name = key[: -len("_cloud_details")]
            gcp = value["gcp"]
            replicas = replica_map.get(res_name, 1)
            resources.append(
                {
                    "name": res_name,
                    "instance_type": gcp["instance_type"],
                    "region": _region_from_zone(gcp["zone"]),
                    "replicas": replicas,
                    "preemptible": gcp.get("preemptible", False),
                }
            )

        # Lists (e.g., kubelet_details = [ … ]) --------
        elif key.endswith("_details") and isinstance(value, list):
            for idx, item in enumerate(value):
                gcp = item["gcp"]
                resources.append(
                    {
                        "name": f"{key[:-len('_details')]}[{idx}]",
                        "instance_type": gcp["instance_type"],
                        "region": _region_from_zone(gcp["zone"]),
                        "replicas": item.get("replicas", 1),
                        "preemptible": gcp.get("preemptible", False),
                    }
                )

    return resources


def main():
    parser = argparse.ArgumentParser(description="GCP cost calculator for tfvars")
    parser.add_argument("tfvars", type=pathlib.Path)
    args = parser.parse_args()

    resources = _parse_tfvars(args.tfvars)

    rows = []
    grand_total = 0.0

    for res in resources:
        price_hour = _fetch_price(
            res["instance_type"], res["region"], res["preemptible"]
        )
        cost = price_hour * res["replicas"]
        grand_total += cost
        rows.append(
            [
                res["name"],
                res["instance_type"],
                res["region"],
                "spot" if res["preemptible"] else "on-demand",
                res["replicas"],
                f"${price_hour:,.4f}",
                f"${cost:,.2f}",
            ]
        )

    print(
        tabulate(
            rows,
            headers=[
                "Resource",
                "Machine-type",
                "Region",
                "Price class",
                "Replicas",
                "Unit $/hr",
                "Total $/hr",
            ],
            floatfmt="",
            tablefmt="github",
        )
    )
    print(f"\n**Grand total:**  **${grand_total:,.2f} per hour**")


if __name__ == "__main__":
    main()

