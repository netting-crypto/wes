from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from .profiles import REPO_ROOT, ToolProfile, load_profile


def run_command(command: list[str], *, cwd: Path) -> None:
    completed = subprocess.run(command, cwd=str(cwd))
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)


def ensure_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def write_markdown_report(path: Path, profile: ToolProfile, out_root: Path, results_dir: Path, site_dir: Path | None) -> None:
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines = [
        f"# {profile.title} 运行摘要",
        "",
        f"- 生成时间：`{generated_at}`",
        f"- profile：`{profile.profile_id}`",
        f"- 疾病范围：`{profile.disease_name}`",
        f"- 候选输入：`{profile.candidate_table}`",
        f"- 单细胞证据清单：`{profile.manifest}`",
        f"- 原始数据目录：`{profile.download_dir}`",
        f"- 结果目录：`{results_dir}`",
    ]
    if site_dir is not None:
        lines.append(f"- 站点目录：`{site_dir}`")
    lines.extend(
        [
            "",
            "## 本次输出",
            "",
            "- `gene_priority_ranking.tsv`：基因级优先级排序",
            "- `variant_priority_ranking.tsv`：变异级优先级排序",
            "- `evidence_breakdown.tsv`：证据拆解明细",
            "- `network_module_summary.tsv`：网络模块汇总",
            "- `summary.json`：结果摘要",
        ]
    )
    if site_dir is not None:
        lines.append("- 网站输出：交互式解释站点")
    lines.extend(
        [
            "",
            "## 说明",
            "",
            "这个 CLI 不重写现有分析脚本，而是把候选输入、疾病 profile、排序结果和站点输出串成一个统一入口。",
            f"当前默认 profile 是 `{profile.profile_id}`，后续新增其他疾病时，只需要提供同 schema 的 profile 与数据目录即可复用同一条工具链。",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def copy_profile_snapshot(profile_path: Path, out_root: Path) -> None:
    ensure_dir(out_root / "profile")
    shutil.copy2(profile_path, out_root / "profile" / profile_path.name)


def build_site(profile: ToolProfile, results_dir: Path, site_dir: Path) -> None:
    ensure_dir(site_dir.parent)
    command = [
        sys.executable,
        "scripts/build_scrna_explorer.py",
        "--results-dir",
        str(results_dir),
        "--site-dir",
        str(site_dir),
    ]
    if profile.normal_retina_dir:
        command.extend(["--normal-retina-dir", str(profile.normal_retina_dir)])
    run_command(command, cwd=REPO_ROOT)


def run_scoring(profile: ToolProfile, results_dir: Path) -> None:
    ensure_dir(results_dir)
    command = [
        sys.executable,
        "scripts/scrna-rp-rank.py",
        "--manifest",
        str(profile.manifest),
        "--download-dir",
        str(profile.download_dir),
        "--status",
        str(profile.download_status),
        "--candidate-table",
        str(profile.candidate_table),
        "--out-dir",
        str(results_dir),
    ]
    if profile.public_gene_table:
        command.extend(["--public-gene-table", str(profile.public_gene_table)])
    run_command(command, cwd=REPO_ROOT)


def command_run(args: argparse.Namespace) -> None:
    profile_path = Path(args.profile)
    if not profile_path.is_absolute():
        profile_path = REPO_ROOT / profile_path
    profile = load_profile(profile_path)
    out_root = Path(args.out_root) if args.out_root else profile.default_out_root
    if not out_root.is_absolute():
        out_root = REPO_ROOT / out_root
    results_dir = ensure_dir(out_root / "results")
    site_dir = out_root / profile.site_slug

    run_scoring(profile, results_dir)
    if args.build_site:
        build_site(profile, results_dir, site_dir)

    copy_profile_snapshot(profile_path, out_root)
    write_json(
        out_root / "run_summary.json",
        {
            "profile": profile.to_summary(),
            "out_root": str(out_root),
            "results_dir": str(results_dir),
            "site_dir": str(site_dir if args.build_site else ""),
            "build_site": bool(args.build_site),
        },
    )
    write_markdown_report(out_root / "run_report.md", profile, out_root, results_dir, site_dir if args.build_site else None)
    print(json.dumps({"out_root": str(out_root), "results_dir": str(results_dir), "site_dir": str(site_dir if args.build_site else "")}, ensure_ascii=False, indent=2))


def command_build_site(args: argparse.Namespace) -> None:
    profile = load_profile(args.profile)
    results_dir = Path(args.results_dir)
    if not results_dir.is_absolute():
        results_dir = REPO_ROOT / results_dir
    site_dir = Path(args.site_dir)
    if not site_dir.is_absolute():
        site_dir = REPO_ROOT / site_dir
    build_site(profile, results_dir, site_dir)
    print(f"site built: {site_dir}")


def command_show_profile(args: argparse.Namespace) -> None:
    profile = load_profile(args.profile)
    print(json.dumps(profile.to_summary(), ensure_ascii=False, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="WES 解释增强工具 CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="按 profile 跑完整解释增强链路")
    run_parser.add_argument("--profile", required=True, help="profile JSON 路径")
    run_parser.add_argument("--out-root", default="", help="本次运行输出根目录")
    run_parser.add_argument("--build-site", action="store_true", help="同时构建交互式网站")
    run_parser.set_defaults(func=command_run)

    site_parser = subparsers.add_parser("build-site", help="只从已有结果构建网站")
    site_parser.add_argument("--profile", required=True, help="profile JSON 路径")
    site_parser.add_argument("--results-dir", required=True, help="排序结果目录")
    site_parser.add_argument("--site-dir", required=True, help="网站输出目录")
    site_parser.set_defaults(func=command_build_site)

    show_parser = subparsers.add_parser("show-profile", help="打印 profile 解析结果")
    show_parser.add_argument("--profile", required=True, help="profile JSON 路径")
    show_parser.set_defaults(func=command_show_profile)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
