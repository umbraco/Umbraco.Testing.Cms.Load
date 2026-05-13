"""
Shared building blocks for scenario locustfiles.

Each scenario ships its own locustfile at loadtests/scenarios/<Name>/locustfile.py
and imports from here. Azure Load Testing flattens testPlan + configurationFiles
into one engine working dir, so `from _helpers import ...` resolves both on ALT
(flat layout) and locally (nested layout - locustfiles add the parent dir to
sys.path before importing; see the snippet at the top of each scenario file).

Contents:
  - INVENTORY_PATH / DELIVERY_API_LIST_PATH: endpoint constants.
  - register_inventory_probe(): wires a test_start listener that fetches the
    seeder inventory and buckets URLs onto environment.urls.
  - register_delivery_api_probe(): wires a test_start listener that probes the
    Delivery API and seeds environment.delivery_ids when reachable.
  - pick_url(user, bucket, name): pick a random URL from a probed bucket.
    Raises on empty bucket so a misconfigured run (seeder didn't seed, probe
    failed) surfaces as a visible 100%-error task rather than silently
    distorting the workload with fallback traffic.

Scenarios declare their own @task methods explicitly so the workload that
runs for a given scenario is fully visible in that scenario's locustfile.
"""

import logging
import random

import requests
from locust import events

logger = logging.getLogger(__name__)

INVENTORY_PATH = "/umbraco/api/seederstatus/inventory"
DELIVERY_API_LIST_PATH = "/umbraco/delivery/api/v2/content"


def register_inventory_probe():
    """Fetch the seeded URL inventory at test start and bucket by content type."""
    @events.test_start.add_listener
    def _on_start(environment, **_):
        environment.urls = {"section": [], "category": [], "page": [], "detail": [], "media": []}
        if not environment.host:
            logger.warning("No host configured; skipping inventory probe")
            return

        try:
            response = requests.get(environment.host.rstrip("/") + INVENTORY_PATH, timeout=15)
            response.raise_for_status()
            data = response.json()
        except (requests.RequestException, ValueError) as ex:
            logger.warning(f"Inventory unreachable ({ex}); falling back to homepage-only")
            return

        if not isinstance(data, dict):
            logger.warning(f"Inventory returned non-object JSON ({type(data).__name__})")
            return

        # Defensive filtering - a single malformed sample would otherwise crash
        # the listener and skip workload setup for every VU in this engine.
        samples = [s for s in data.get("sampleContentUrls", []) if isinstance(s, dict) and "url" in s]
        environment.urls = {
            "section":  [u for u in data.get("rootSectionUrls", []) if isinstance(u, str)],
            "category": [s["url"] for s in samples if s.get("docType") == "Category"],
            "page":     [s["url"] for s in samples if s.get("docType") == "Page"],
            "detail":   [s["url"] for s in samples if s.get("docType") == "Detail"],
            "media":    [u for u in data.get("sampleMediaUrls", []) if isinstance(u, str)],
        }
        counts = ", ".join(f"{k}={len(v)}" for k, v in environment.urls.items())
        logger.info(f"Inventory loaded: {counts}")


def register_delivery_api_probe():
    """Probe the Delivery API at test start. On 200 seed environment.delivery_ids."""
    @events.test_start.add_listener
    def _on_start(environment, **_):
        environment.delivery_ids = []
        if not environment.host:
            return

        try:
            response = requests.get(
                environment.host.rstrip("/") + DELIVERY_API_LIST_PATH + "?take=50",
                timeout=10,
            )
        except requests.RequestException as ex:
            logger.warning(f"Delivery API probe failed ({ex})")
            return

        if response.status_code != 200:
            logger.warning(f"Delivery API probe returned {response.status_code} (expected 200 in this scenario)")
            return

        try:
            body = response.json()
        except ValueError:
            logger.warning("Delivery API probe returned 200 but body was not JSON")
            return

        if not isinstance(body, dict):
            return

        items = body.get("items", [])
        environment.delivery_ids = [i["id"] for i in items if isinstance(i, dict) and "id" in i]
        logger.info(f"Delivery API enabled: {len(environment.delivery_ids)} items inventoried")


def pick_url(user, bucket: str, name: str) -> None:
    """Pick a random URL from a probed bucket. Raises on empty bucket."""
    urls = user.environment.urls.get(bucket)
    if not urls:
        raise RuntimeError(f"Bucket '{bucket}' is empty - inventory probe failed or seeder didn't seed it")
    user.client.get(random.choice(urls), name=name)
