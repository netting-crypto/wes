import argparse
import csv
import re
from pathlib import Path


LAB_INDEX = 3
GENE_INDEX = 5
COORD_INDEX = 7
VARIANT_INDEX = 8
CLASS_INDEX = 11
CONCLUSION_INDEX = 12


def normalize_chrom(chrom: str) -> str:
    chrom = chrom.strip()
    if chrom.lower().startswith("chr"):
        return chrom
    if chrom in {"M", "MT"}:
        return "chrM"
    return f"chr{chrom}"


def chrom_sort_key(chrom: str):
    base = chrom[3:] if chrom.lower().startswith("chr") else chrom
    order = {"X": 23, "Y": 24, "M": 25, "MT": 25}
    if base.isdigit():
        return (0, int(base))
    if base in order:
        return (1, order[base])
    return (2, base)


def parse_coordinate(value: str):
    raw = value.strip()
    range_match = re.match(r"^([^:]+):(\d+)-(\d+)([A-Za-z].*)?$", raw)
    if range_match:
        chrom = normalize_chrom(range_match.group(1))
        start_pos = int(range_match.group(2))
        end_pos = int(range_match.group(3))
        ref_len = max(1, end_pos - start_pos + 1)
        return chrom, start_pos, "N" * ref_len, "N"
    if ">" in raw and raw.count(":") == 2:
        chrom, pos_text, ref_alt = raw.split(":", 2)
        ref, alt = ref_alt.split(">", 1)
    else:
        parts = raw.split(":", 3)
        if len(parts) != 4:
            raise ValueError(f"Unsupported coordinate format: {value}")
        chrom, pos_text, ref, alt = parts
    pos = int(pos_text)
    chrom = normalize_chrom(chrom)
    return chrom, pos, ref, alt


def merge_intervals(intervals):
    merged = []
    for chrom, start, end in sorted(intervals, key=lambda item: (chrom_sort_key(item[0]), item[1], item[2])):
        if not merged or merged[-1][0] != chrom or start > merged[-1][2]:
            merged.append([chrom, start, end])
        else:
            merged[-1][2] = max(merged[-1][2], end)
    return merged


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-tsv", required=True)
    parser.add_argument("--output-bed", required=True)
    parser.add_argument("--padding", type=int, default=100)
    parser.add_argument("--output-table")
    args = parser.parse_args()

    input_path = Path(args.input_tsv)
    output_bed = Path(args.output_bed)
    output_bed.parent.mkdir(parents=True, exist_ok=True)

    intervals = []
    records = []
    skipped_records = []

    with input_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle, delimiter="\t")
        header = next(reader, None)
        if header is None:
            raise ValueError("Input TSV is empty")
        if len(header) <= CONCLUSION_INDEX:
            raise ValueError("Unexpected company-analysis-results.tsv layout")

        current_lab = ""
        current_gene = ""
        current_variant = ""
        current_class = ""
        current_conclusion = ""

        for row in reader:
            if len(row) < len(header):
                row.extend([""] * (len(header) - len(row)))

            if row[LAB_INDEX].strip():
                current_lab = row[LAB_INDEX].strip()
            else:
                row[LAB_INDEX] = current_lab

            if row[GENE_INDEX].strip():
                current_gene = row[GENE_INDEX].strip()
            else:
                row[GENE_INDEX] = current_gene

            if row[VARIANT_INDEX].strip():
                current_variant = row[VARIANT_INDEX].strip()
            else:
                row[VARIANT_INDEX] = current_variant

            if row[CLASS_INDEX].strip():
                current_class = row[CLASS_INDEX].strip()
            else:
                row[CLASS_INDEX] = current_class

            if row[CONCLUSION_INDEX].strip():
                current_conclusion = row[CONCLUSION_INDEX].strip()
            else:
                row[CONCLUSION_INDEX] = current_conclusion

            coord = row[COORD_INDEX].strip()
            if not coord or coord == "-":
                continue

            try:
                chrom, pos, ref, alt = parse_coordinate(coord)
            except ValueError:
                skipped_records.append(
                    {
                        "lab_id": row[LAB_INDEX].strip(),
                        "gene": row[GENE_INDEX].strip(),
                        "coordinate": coord,
                    }
                )
                continue
            ref_len = max(1, len(ref))
            start = max(0, pos - 1 - args.padding)
            end = pos - 1 + ref_len + args.padding
            intervals.append((chrom, start, end))
            records.append(
                {
                    "lab_id": row[LAB_INDEX].strip(),
                    "gene": row[GENE_INDEX].strip(),
                    "coordinate": coord,
                    "variant": row[VARIANT_INDEX].strip(),
                    "classification": row[CLASS_INDEX].strip(),
                    "conclusion": row[CONCLUSION_INDEX].strip(),
                    "chrom": chrom,
                    "start": str(start),
                    "end": str(end),
                }
            )

    merged = merge_intervals(intervals)
    with output_bed.open("w", encoding="utf-8", newline="\n") as handle:
        for chrom, start, end in merged:
            handle.write(f"{chrom}\t{start}\t{end}\n")

    if args.output_table:
        output_table = Path(args.output_table)
        output_table.parent.mkdir(parents=True, exist_ok=True)
        fieldnames = [
            "lab_id",
            "gene",
            "coordinate",
            "variant",
            "classification",
            "conclusion",
            "chrom",
            "start",
            "end",
        ]
        with output_table.open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t")
            writer.writeheader()
            writer.writerows(records)

    print(output_bed)
    print(f"source_records={len(records)}")
    print(f"merged_intervals={len(merged)}")
    print(f"skipped_records={len(skipped_records)}")


if __name__ == "__main__":
    main()
