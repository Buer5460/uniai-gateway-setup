"""Canonical install root - one answer, everywhere.

RC3 created a second installation next to the real one: the historical
install lives in ``%LOCALAPPDATA%\\UniAI Gateway`` (``install.json``,
``uniai-agent.exe``, the database that ZCode is actually bound to), while the
installer defaulted to ``%LOCALAPPDATA%\\UniAI`` and happily reported
"no existing installation - clean install". Two roots means two databases,
two key rings and eventually two processes fighting over 8935.

Resolution order:

    1. ``UNIAI_HOME``                       (operator override / tests)
    2. a root that carries ``install.json`` (a real, recorded installation)
    3. a root that carries ``data/uniai.db`` (installed but unrecorded)
    4. the historical default ``%LOCALAPPDATA%\\UniAI Gateway``

An upgrade must recognise the old installation. It must never look like a
clean install, and it must never delete user data.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

PRODUCT = "UniAI Gateway"
#: Historical, stable root - the one the 0.8.0 installer used and the one
#: ZCode is configured against. A new install may not invent a second one.
LEGACY_DIR_NAME = "UniAI Gateway"

LAYOUT = ("app", "data", "runtime")


def local_appdata() -> Path:
    base = os.environ.get("LOCALAPPDATA") or ""
    if base:
        return Path(base)
    return Path.home() / "AppData" / "Local"


def candidates() -> list[Path]:
    roots: list[Path] = []
    env = str(os.environ.get("UNIAI_HOME") or "").strip()
    if env:
        roots.append(Path(env))
    base = local_appdata()
    roots.append(base / LEGACY_DIR_NAME)
    for child in sorted(base.glob("UniAI*")):
        if child.is_dir() and child not in roots:
            roots.append(child)
    return roots


def _score(root: Path) -> tuple[int, list[str]]:
    """Higher is stronger. Never invents anything, only reads."""
    evidence: list[str] = []
    if not root.exists():
        return (-1, evidence)
    score = 0
    install_json = root / "install.json"
    if install_json.exists():
        score += 100
        evidence.append("install.json")
    if (root / "data" / "uniai.db").exists():
        score += 50
        evidence.append("data/uniai.db")
    if (root / "data").is_dir():
        score += 10
        evidence.append("data/")
    if (root / "app" / "VERSION").exists():
        score += 20
        evidence.append("app/VERSION")
    if any((root / name).exists() for name in ("UniAI.exe", "uniai-agent.exe", "_internal")):
        score += 5
        evidence.append("legacy program")
    return (score, evidence)


def resolve_root() -> dict:
    env_override = str(os.environ.get("UNIAI_HOME") or "").strip()
    if env_override:
        # An explicit override is an instruction, not a candidate: honouring it
        # is the only way a test can exercise an isolated root without ever
        # touching the real installation.
        root = Path(env_override)
        data = root / "data"
        legacy_program = [name for name in ("UniAI.exe", "uniai-agent.exe", "_internal")
                          if (root / name).exists()]
        score, evidence = _score(root)
        return {
            "root": str(root),
            "app": str(root / "app"),
            "data": str(data),
            "runtime": str(root / "runtime"),
            "install_json": str(root / "install.json"),
            "source": "UNIAI_HOME",
            "score": score,
            "evidence": evidence or ["UNIAI_HOME override"],
            "legacy_program": legacy_program,
            "is_legacy_layout": bool(legacy_program) and not (root / "app" / "VERSION").exists(),
            "has_data": (data / "uniai.db").exists(),
            "has_app": (root / "app" / "VERSION").exists(),
            "others": [],
        }
    best: Path | None = None
    best_score = -1
    best_evidence: list[str] = []
    for root in candidates():
        score, evidence = _score(root)
        if score > best_score:
            best, best_score, best_evidence = root, score, evidence
    if best is None:
        best = local_appdata() / LEGACY_DIR_NAME
        best_evidence = ["default"]
    root = best
    data = root / "data"
    legacy_program = [name for name in ("UniAI.exe", "uniai-agent.exe", "_internal")
                      if (root / name).exists()]
    others: list[dict] = []
    for cand in candidates():
        if cand == root:
            continue
        cand_score, cand_evidence = _score(cand)
        if cand_score < 0:
            continue
        others.append({
            "root": str(cand),
            "score": cand_score,
            "evidence": cand_evidence,
            "has_install_json": (cand / "install.json").exists(),
            "has_app": (cand / "app").exists(),
            "has_data": (cand / "data").exists(),
        })
    return {
        "others": others,
        "root": str(root),
        "app": str(root / "app"),
        "data": str(data),
        "runtime": str(root / "runtime"),
        "install_json": str(root / "install.json"),
        "source": "UNIAI_HOME" if env_override and Path(env_override) == root else (
            "existing" if best_score >= 50 else "default"),
        "score": best_score,
        "evidence": best_evidence,
        "legacy_program": legacy_program,
        "is_legacy_layout": bool(legacy_program) and not (root / "app" / "VERSION").exists(),
        "has_data": (data / "uniai.db").exists(),
        "has_app": (root / "app" / "VERSION").exists(),
    }


def read_install_json(root: Path | str | None = None) -> dict:
    path = Path(root or resolve_root()["root"]) / "install.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return {}


def port(root: Path | str | None = None) -> int:
    """The port the installation actually uses: runtime state wins, then the
    recorded installation, then the default."""
    info = resolve_root() if root is None else {
        "root": str(root), "data": str(Path(root) / "data")}
    pid_file = Path(info["data"]) / "run" / "uniai.pid"
    if pid_file.exists():
        try:
            payload = json.loads(pid_file.read_text(encoding="utf-8"))
            value = int(payload.get("port") or 0)
            if value:
                return value
        except Exception:  # noqa: BLE001
            try:
                return int(pid_file.read_text(encoding="utf-8").strip())
            except Exception:  # noqa: BLE001
                pass
    recorded = read_install_json(info["root"])
    try:
        return int(recorded.get("port") or 8935)
    except Exception:  # noqa: BLE001
        return 8935


def migration_plan(root: Path | str | None = None) -> dict:
    """What an upgrade has to do - described, never executed here.

    The rule that matters: ``data`` is moved by nobody, ever. Only program
    files are replaced, and only after the replacement answers /health.
    """
    info = resolve_root() if root is None else resolve_root()
    actions: list[str] = []
    if info["has_data"]:
        actions.append("keep data (database, keys, vault, logs)")
    else:
        actions.append("create empty data directory")
    if info["is_legacy_layout"]:
        actions.append("back up legacy program files, keep them until health is proven")
    if info["has_app"]:
        actions.append("back up app -> app.previous, then replace program files")
    else:
        actions.append("install program files into app/")
    return {
        "root": info["root"],
        "source": info["source"],
        "evidence": info["evidence"],
        "legacy_program": info["legacy_program"],
        "actions": actions,
        "never": ["delete data", "rotate keys", "rewrite ZCode configuration",
                  "delete legacy program files before /health is 200"],
    }


def write_install_json(version: str, root: Path | str | None = None) -> dict:
    """Record this installation - merged with whatever was there before.

    Only program identity changes here. ``data_dir`` is preserved verbatim: an
    installer that rewrites it would move a user's database.
    """
    info = resolve_root() if root is None else resolve_root()
    target = Path(info["install_json"])
    existing: dict = {}
    if target.exists():
        try:
            existing = json.loads(target.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            existing = {}
    payload = dict(existing)
    payload.update({
        "product": PRODUCT,
        "version": version,
        "install_dir": info["root"],
        "install_root": info["root"],
        "app_dir": info["app"],
        "runtime_dir": info["runtime"],
        "data_dir": existing.get("data_dir") or info["data"],
        "port": port(info["root"]),
        "layout": "app-data-runtime",
    })
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return payload


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--plan", action="store_true")
    parser.add_argument("--port", action="store_true")
    parser.add_argument("--write-install", metavar="VERSION", default="")
    args = parser.parse_args()
    if args.write_install:
        import json as _json
        print(_json.dumps(write_install_json(args.write_install), ensure_ascii=False, indent=2))
        return 0
    if args.port:
        print(port())
        return 0
    if args.plan:
        import json as _json
        print(_json.dumps(migration_plan(), ensure_ascii=False, indent=2))
        return 0
    import json as _json
    print(_json.dumps(resolve_root(), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
