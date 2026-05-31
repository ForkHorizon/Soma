from __future__ import annotations

import shutil
import subprocess

from .graph_storage_paths import GraphStoragePathsMixin
from .graph_storage_refresh import GraphStorageRefreshMixin
from .graph_storage_reports import GraphStorageReportsMixin
from .graph_storage_status import GraphStorageStatusMixin
from .graph_storage_utils import GRAPHIFY_BASE_DIR, GRAPH_STALE_SECONDS


class GraphStorageManager(
    GraphStorageRefreshMixin,
    GraphStorageReportsMixin,
    GraphStorageStatusMixin,
    GraphStoragePathsMixin,
):
    """Managed Graphify storage facade used by the gateway."""


__all__ = [
    "GRAPHIFY_BASE_DIR",
    "GRAPH_STALE_SECONDS",
    "GraphStorageManager",
    "shutil",
    "subprocess",
]
