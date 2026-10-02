"""Allow-listed model-specific llama integration registry."""
from __future__ import annotations

from .gemma4_kv_array import Gemma4KVArrayIntegration
from .qwen38_ktopt_docker import Qwen38KToptDockerIntegration
from .ternary_bonsai_prism import TernaryBonsaiPrismIntegration

INTEGRATIONS = (
    Gemma4KVArrayIntegration(),
    TernaryBonsaiPrismIntegration(),
    Qwen38KToptDockerIntegration(),
)
BY_ID = {integration.id: integration for integration in INTEGRATIONS}


def get_integration(integration_id: str):
    try:
        return BY_ID[integration_id]
    except KeyError as exc:
        raise ValueError(f"unknown model integration {integration_id!r}") from exc


def resolve_integration(repository: str = "", filename: str = "", architecture: str = ""):
    matches = []
    for integration in INTEGRATIONS:
        score = integration.match_score(repository, filename, architecture)
        if score is not None:
            matches.append((score, integration))
    if not matches:
        return None
    best_score = max(score for score, _ in matches)
    best = [integration for score, integration in matches if score == best_score]
    if len(best) != 1:
        ids = ", ".join(sorted(integration.id for integration in best))
        raise ValueError(f"ambiguous model integration match: {ids}")
    return best[0]
