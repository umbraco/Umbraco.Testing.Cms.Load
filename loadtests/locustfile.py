"""
Workload that mirrors a realistic CMS browsing pattern.

On test start, fetches the seeder's inventory endpoint, buckets the URLs by
content type, and stashes the result on the locust environment. Tasks pick
a random URL from their bucket. Weights skew toward deep reads (Detail
pages) because that's where SQL pressure surfaces — homepage hits are
absorbed by output cache and don't differentiate tiers.

If the inventory endpoint is unreachable (seeder didn't run, scenario
overlay disabled it), every task falls back to the homepage so the run
still produces stats — just without the differentiating signal.
"""

import logging
import random

import requests
from locust import FastHttpUser, between, events, task

logger = logging.getLogger(__name__)

INVENTORY_PATH = "/umbraco/api/seederstatus/inventory"
INVENTORY_TIMEOUT_SEC = 15


@events.test_start.add_listener
def fetch_inventory(environment, **_):
    """Fetch the seeded URL inventory once and bucket the URLs by content type."""
    environment.inventory = {}
    if not environment.host:
        logger.warning("No host configured; skipping inventory fetch")
        return

    url = environment.host.rstrip("/") + INVENTORY_PATH
    try:
        response = requests.get(url, timeout=INVENTORY_TIMEOUT_SEC)
        response.raise_for_status()
        data = response.json()
    except requests.RequestException as ex:
        logger.warning(f"Inventory fetch failed ({ex}); falling back to homepage-only")
        return

    samples = data.get("sampleContentUrls", [])
    environment.inventory = {
        "section":  data.get("rootSectionUrls", []),
        "category": [s["url"] for s in samples if s.get("docType") == "Category"],
        "page":     [s["url"] for s in samples if s.get("docType") == "Page"],
        "detail":   [s["url"] for s in samples if s.get("docType") == "Detail"],
        "media":    data.get("sampleMediaUrls", []),
    }
    logger.info(
        f"Inventory loaded: "
        f"{len(environment.inventory['section'])} sections, "
        f"{len(environment.inventory['category'])} categories, "
        f"{len(environment.inventory['page'])} pages, "
        f"{len(environment.inventory['detail'])} details, "
        f"{len(environment.inventory['media'])} media"
    )


class CmsBrowsingUser(FastHttpUser):
    wait_time = between(1, 3)

    def _hit(self, bucket: str, name: str) -> None:
        """Pick a random URL from a pre-built bucket; fall back to homepage if empty."""
        urls = self.environment.inventory.get(bucket)
        if not urls:
            self.client.get("/", name="Homepage (fallback)")
            return
        self.client.get(random.choice(urls), name=name)

    @task(5)
    def homepage(self):
        self.client.get("/", name="Homepage")

    @task(10)
    def section(self):
        self._hit("section", "Section")

    @task(20)
    def category(self):
        self._hit("category", "Category")

    @task(30)
    def page(self):
        self._hit("page", "Page")

    @task(35)
    def detail(self):
        # Detail pages are the deepest read path (most joins / property loads),
        # so they're weighted highest — that's where SQL pressure surfaces.
        self._hit("detail", "Detail")

    @task(5)
    def media(self):
        self._hit("media", "Media")
