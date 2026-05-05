from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _repo_path(raw: str | None) -> Path | None:
    if not raw:
        return None
    path = Path(raw)
    return path if path.is_absolute() else (REPO_ROOT / path)


@dataclass
class ToolProfile:
    profile_id: str
    disease_name: str
    title: str
    description: str
    manifest: Path
    download_dir: Path
    download_status: Path
    candidate_table: Path
    public_gene_table: Path | None
    normal_retina_dir: Path | None
    default_out_root: Path
    site_slug: str

    @classmethod
    def from_json(cls, path: Path) -> "ToolProfile":
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
        return cls(
            profile_id=payload["profile_id"],
            disease_name=payload["disease_name"],
            title=payload["title"],
            description=payload["description"],
            manifest=_repo_path(payload["manifest"]),
            download_dir=_repo_path(payload["download_dir"]),
            download_status=_repo_path(payload["download_status"]),
            candidate_table=_repo_path(payload["candidate_table"]),
            public_gene_table=_repo_path(payload.get("public_gene_table")),
            normal_retina_dir=_repo_path(payload.get("normal_retina_dir")),
            default_out_root=_repo_path(payload["default_out_root"]),
            site_slug=payload.get("site_slug", "wes-evidence-explorer"),
        )

    def to_summary(self) -> dict[str, str]:
        return {
            "profile_id": self.profile_id,
            "disease_name": self.disease_name,
            "title": self.title,
            "description": self.description,
            "manifest": str(self.manifest),
            "download_dir": str(self.download_dir),
            "download_status": str(self.download_status),
            "candidate_table": str(self.candidate_table),
            "public_gene_table": str(self.public_gene_table or ""),
            "normal_retina_dir": str(self.normal_retina_dir or ""),
            "default_out_root": str(self.default_out_root),
            "site_slug": self.site_slug,
        }


def load_profile(path: str | Path) -> ToolProfile:
    profile_path = Path(path)
    if not profile_path.is_absolute():
        profile_path = REPO_ROOT / profile_path
    return ToolProfile.from_json(profile_path)
