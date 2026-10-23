"""Candidate record emitter — writes <idx>-<source>.<ext> + sidecar .meta.json."""
from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path


@dataclass
class Candidate:
    slug: str
    source: str   # wikipedia|twitter|github|models_dev|favicon|bing_image
    tier: int
    url: str
    content: bytes
    ext: str
    extra: dict = field(default_factory=dict)

    def sha256(self) -> str:
        return hashlib.sha256(self.content).hexdigest()

    def emit(self, out_dir: Path, idx: int) -> dict:
        out_dir.mkdir(parents=True, exist_ok=True)
        ext = self.ext.lstrip(".")
        file_name = f"{idx:02d}-{self.source}.{ext}"
        path = out_dir / file_name
        path.write_bytes(self.content)
        meta = {
            "slug": self.slug,
            "source": self.source,
            "tier": self.tier,
            "url": self.url,
            "fetched_at": int(time.time()),
            "sha256": self.sha256(),
            "bytes": len(self.content),
            "path": str(path),
            **self.extra,
        }
        (out_dir / f"{file_name}.meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        return meta
