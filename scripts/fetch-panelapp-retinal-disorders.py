#!/usr/bin/env python3
import argparse
import csv
import json
import urllib.request
from pathlib import Path


API_URL = "https://panelapp.genomicsengland.co.uk/api/v1/panels/307/?format=json"


def is_rp_related(phenotypes):
    text = " | ".join(phenotypes).lower()
    tokens = [
        "retinitis pigmentosa",
        "rod-cone dystrophy",
        "rod dysfunction",
        "retinal dystrophy",
        "leber congenital amaurosis",
        "early-onset severe retinal dystrophy",
    ]
    return any(token in text for token in tokens)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    request = urllib.request.Request(
        API_URL,
        headers={
            "User-Agent": "Mozilla/5.0",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=120) as resp:
        payload = json.load(resp)

    rows = []
    for gene in payload.get("genes", []):
        if gene.get("entity_type") != "gene":
            continue
        gene_data = gene.get("gene_data", {})
        phenotypes = gene.get("phenotypes") or []
        rows.append({
            "source": "PanelApp",
            "panel_id": str(payload.get("id", "")),
            "panel_name": payload.get("name", ""),
            "panel_version": payload.get("version", ""),
            "gene": gene.get("entity_name", "") or gene_data.get("gene_symbol", ""),
            "confidence_level": gene.get("confidence_level", ""),
            "mode_of_inheritance": gene.get("mode_of_inheritance", ""),
            "evidence": ";".join(gene.get("evidence") or []),
            "phenotypes": ";".join(phenotypes),
            "rp_related": "yes" if is_rp_related(phenotypes) else "no",
        })

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()), delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
