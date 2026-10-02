#!/usr/bin/env python3
"""Static checks for the wimpy llama-hugs YAML configuration."""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from yaml.constructor import ConstructorError
from yaml.nodes import MappingNode

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "llama-hugs-config.yaml"
ALLOWED_TOP_LEVEL_KEYS = {"healthCheckTimeout", "groups", "models", "store"}
GPU_GROUPS = {
    "amd-r9700": ("HIP_VISIBLE_DEVICES", "ROCm0"),
    "nvidia-5060ti": ("CUDA_VISIBLE_DEVICES", "CUDA0"),
}
PORT_PLACEHOLDER = "${PORT}"


@dataclass(frozen=True)
class LintIssue:
    severity: str
    code: str
    location: str
    message: str


class UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML loader that rejects duplicate mapping keys."""

    def construct_mapping(self, node: MappingNode, deep: bool = False) -> dict[Any, Any]:
        self.flatten_mapping(node)
        mapping: dict[Any, Any] = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            try:
                duplicate = key in mapping
            except TypeError as exc:
                raise ConstructorError(
                    "while constructing a mapping",
                    node.start_mark,
                    "found an unhashable mapping key",
                    key_node.start_mark,
                ) from exc
            if duplicate:
                raise ConstructorError(
                    "while constructing a mapping",
                    node.start_mark,
                    f"duplicate key {key!r}",
                    key_node.start_mark,
                )
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def _issue(
    severity: str, code: str, location: str, message: str
) -> LintIssue:
    return LintIssue(severity, code, location, message)


def lint_text(text: str, *, require_store: bool = False) -> list[LintIssue]:
    """Lint YAML text and return actionable errors and warnings."""
    try:
        config = yaml.load(text, Loader=UniqueKeyLoader)
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        location = (
            f"line {mark.line + 1}, column {mark.column + 1}" if mark else "YAML"
        )
        message = getattr(exc, "problem", None) or str(exc).splitlines()[0]
        return [_issue("error", "yaml.parse", location, message)]
    return lint_config_data(config, require_store=require_store)


def lint_file(path: str | Path, *, require_store: bool = False) -> list[LintIssue]:
    """Read and lint a config file."""
    config_path = Path(path)
    try:
        text = config_path.read_text(encoding="utf-8")
    except OSError as exc:
        return [_issue("error", "file.read", str(config_path), str(exc))]
    return lint_text(text, require_store=require_store)


def lint_config_data(config: Any, *, require_store: bool = False) -> list[LintIssue]:
    """Lint a parsed source or generated llama-hugs config mapping."""
    issues: list[LintIssue] = []
    if not isinstance(config, dict):
        return [_issue("error", "config.root_type", "$", "expected a YAML mapping")]

    for key in config:
        if key not in ALLOWED_TOP_LEVEL_KEYS:
            issues.append(
                _issue(
                    "error",
                    "config.unknown_key",
                    str(key),
                    f"unrecognized top-level key {key!r}; check for a typo",
                )
            )

    for required in ("healthCheckTimeout", "groups", "models"):
        if required not in config:
            issues.append(
                _issue("error", "config.missing_key", required, "required key is missing")
            )

    timeout = config.get("healthCheckTimeout")
    if timeout is not None and (type(timeout) is not int or timeout <= 0):
        issues.append(
            _issue(
                "error",
                "config.health_check_timeout",
                "healthCheckTimeout",
                "must be a positive integer number of seconds",
            )
        )

    if "store" not in config:
        severity = "error" if require_store else "warning"
        issues.append(
            _issue(
                severity,
                "store.missing",
                "store.path",
                "no persistent SQLite store is configured; the generated live config should set store.path",
            )
        )
    else:
        store = config["store"]
        if not isinstance(store, dict):
            issues.append(
                _issue("error", "store.type", "store", "must be a mapping")
            )
        else:
            store_path = store.get("path")
            if not isinstance(store_path, str) or not store_path.strip():
                issues.append(
                    _issue("error", "store.path", "store.path", "must be a non-empty path")
                )
            elif not Path(store_path).is_absolute():
                issues.append(
                    _issue("error", "store.path_relative", "store.path", "must be absolute so service restarts keep using the same SQLite file")
                )

    models = config.get("models")
    if not isinstance(models, dict):
        issues.append(_issue("error", "models.type", "models", "must be a mapping"))
        models = {}
    elif not models:
        issues.append(_issue("error", "models.empty", "models", "must contain at least one model"))

    groups = config.get("groups")
    memberships: dict[str, list[str]] = {}
    if not isinstance(groups, dict):
        issues.append(_issue("error", "groups.type", "groups", "must be a mapping"))
        groups = {}
    elif not groups:
        issues.append(_issue("error", "groups.empty", "groups", "must contain at least one group"))

    for group_name, group in groups.items():
        group_location = f"groups.{group_name}"
        if not isinstance(group, dict):
            issues.append(
                _issue("error", "group.type", group_location, "must be a mapping")
            )
            continue
        members = group.get("members")
        if not isinstance(members, list):
            issues.append(
                _issue(
                    "error", "group.members_type", f"{group_location}.members", "must be a list"
                )
            )
            continue
        seen: set[str] = set()
        for index, model_id in enumerate(members):
            location = f"{group_location}.members[{index}]"
            if not isinstance(model_id, str) or not model_id:
                issues.append(
                    _issue("error", "group.member_type", location, "must be a non-empty model ID")
                )
                continue
            if model_id in seen:
                issues.append(
                    _issue("error", "group.duplicate_member", location, f"duplicate member {model_id!r}")
                )
                continue
            seen.add(model_id)
            memberships.setdefault(model_id, []).append(str(group_name))
            if model_id not in models:
                issues.append(
                    _issue("error", "group.missing_model", location, f"model {model_id!r} is not defined")
                )

    for model_id in models:
        groups_for_model = memberships.get(model_id, [])
        if not groups_for_model:
            issues.append(
                _issue("error", "model.ungrouped", f"models.{model_id}", "model is not assigned to a group")
            )
        elif len(groups_for_model) > 1:
            issues.append(
                _issue(
                    "error",
                    "model.multiple_groups",
                    f"models.{model_id}",
                    f"model is assigned to multiple groups: {', '.join(groups_for_model)}",
                )
            )

    for model_id, entry in models.items():
        location = f"models.{model_id}"
        if not isinstance(model_id, str) or not model_id:
            issues.append(_issue("error", "model.id", "models", "model IDs must be non-empty strings"))
            continue
        if not isinstance(entry, dict):
            issues.append(_issue("error", "model.type", location, "must be a mapping"))
            continue

        cmd = entry.get("cmd")
        if not isinstance(cmd, str) or not cmd.strip():
            issues.append(_issue("error", "model.cmd", f"{location}.cmd", "must be a non-empty command string"))
            cmd = ""
        else:
            if PORT_PLACEHOLDER not in cmd:
                issues.append(
                    _issue(
                        "error",
                        "cmd.missing_port_placeholder",
                        f"{location}.cmd",
                        f"must include {PORT_PLACEHOLDER} so llama-hugs can assign the model port",
                    )
                )
            if re.search(r"(?:^|\s)--port(?:=|\s+)(?:--|\s*$)", cmd):
                issues.append(
                    _issue("error", "cmd.empty_port", f"{location}.cmd", "--port has no value")
                )
            if re.search(r"(?:^|\s)(?:-hf(?:-[\w-]+)?|--hf-repo)(?:=|\s|$)", cmd):
                issues.append(
                    _issue("error", "cmd.remote_model", f"{location}.cmd", "use the already-downloaded local model path, not a Hugging Face download flag")
                )
            if "llama-server" in cmd:
                model_arg = re.search(r"(?:^|\s)(?:--model|-m)(?:=|\s+)([^\s]+)", cmd)
                if not model_arg:
                    issues.append(
                        _issue("error", "cmd.local_model_path", f"{location}.cmd", "llama-server command must use --model or -m with a local path")
                    )
                else:
                    model_path = model_arg.group(1).replace(r"\n", "")
                    if not model_path.startswith("/"):
                        issues.append(
                            _issue("error", "cmd.local_model_path", f"{location}.cmd", "llama-server model path must be absolute")
                        )

        env = entry.get("env", [])
        if not isinstance(env, list) or any(not isinstance(item, str) for item in env):
            issues.append(
                _issue("error", "model.env_type", f"{location}.env", "must be a list of KEY=VALUE strings")
            )
            env = []
        else:
            for index, item in enumerate(env):
                if "=" not in item or not item.split("=", 1)[0]:
                    issues.append(
                        _issue("error", "model.env_entry", f"{location}.env[{index}]", "must use KEY=VALUE form")
                    )
        env_names = [item.split("=", 1)[0] for item in env if "=" in item]
        for env_name in sorted({name for name in env_names if env_names.count(name) > 1}):
            issues.append(
                _issue("error", "model.env_duplicate", f"{location}.env", f"environment key {env_name!r} is repeated")
            )

        for group_name in memberships.get(model_id, []):
            policy = GPU_GROUPS.get(group_name)
            if not policy:
                continue
            env_name, device = policy
            values = [item.split("=", 1)[1] for item in env if item.startswith(f"{env_name}=")]
            valid_pin = (
                len(values) == 1
                and (bool(re.fullmatch(r"GPU-(?:[0-9A-Fa-f]{16}|[0-9A-Fa-f]{32}|[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})", values[0])) if env_name == "HIP_VISIBLE_DEVICES" else values[0] == "0")
            )
            if not valid_pin:
                expected = "a stable GPU-UUID" if env_name == "HIP_VISIBLE_DEVICES" else "exactly 0"
                issues.append(
                    _issue("error", "gpu.env_pin", f"{location}.env", f"{group_name} requires {env_name}={expected}")
                )

            is_docker = bool(re.search(r"(?:^|\s)(?:\S*/)?docker\s", cmd))
            if is_docker:
                if "--gpus" not in cmd:
                    issues.append(
                        _issue("error", "gpu.container_pin", f"{location}.cmd", "Docker model command must explicitly request a GPU with --gpus")
                    )
            elif "model_integrations/launcher.py" in cmd:
                if not re.search(rf"(?:^|\s)--backend(?:=|\s+){re.escape(device)}(?=\s|$)", cmd):
                    issues.append(
                        _issue("error", "gpu.device_mismatch", f"{location}.cmd", f"{group_name} integration must select --backend {device}")
                    )
            elif not re.search(rf"(?:^|\s)(?:--device|-dev)(?:=|\s+){re.escape(device)}(?=\s|$)", cmd):
                issues.append(
                    _issue("error", "gpu.device_mismatch", f"{location}.cmd", f"{group_name} command must pin --device {device} (or llama.cpp's -dev abbreviation)")
                )

        capabilities = entry.get("capabilities", {})
        if capabilities is not None and not isinstance(capabilities, dict):
            issues.append(
                _issue("error", "model.capabilities_type", f"{location}.capabilities", "must be a mapping")
            )
        elif isinstance(capabilities, dict) and "context" in capabilities:
            context = capabilities["context"]
            if type(context) is not int or context <= 0:
                issues.append(
                    _issue("error", "model.context_type", f"{location}.capabilities.context", "must be a positive integer")
                )
            elif context < 65536:
                issues.append(
                    _issue("warning", "model.context_below_64k", f"{location}.capabilities.context", f"{context} is below the 65536-token Hermes minimum")
                )

    return issues


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "config",
        nargs="?",
        type=Path,
        default=DEFAULT_CONFIG,
        help=f"config file to lint (default: {DEFAULT_CONFIG})",
    )
    parser.add_argument(
        "--require-store",
        action="store_true",
        help="treat a missing persistent SQLite store.path as an error (use for live/generated configs)",
    )
    args = parser.parse_args(argv)

    issues = lint_file(args.config, require_store=args.require_store)
    for issue in issues:
        print(f"{issue.severity.upper()} [{issue.code}] {issue.location}: {issue.message}")
    errors = sum(issue.severity == "error" for issue in issues)
    warnings = sum(issue.severity == "warning" for issue in issues)
    print(f"linted {args.config}: {errors} error(s), {warnings} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
