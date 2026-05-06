"""
Workload that exercises a realistic-ish CMS browsing pattern + a small
write path. Designed for *relative* comparison across Umbraco versions
and Azure SQL tiers, not as an absolute capacity benchmark.

On test start, fetches the seeder's inventory endpoint, buckets the URLs
by content type, and stashes the result on the locust environment. Tasks
pick a random URL from their bucket. Weights skew toward deep reads
(Detail pages) because that's where SQL pressure surfaces — homepage
hits are absorbed by output cache and don't differentiate tiers.

If the inventory endpoint is unreachable (seeder didn't run, scenario
overlay disabled it), every task falls back to the homepage so the run
still produces stats — just without the differentiating signal.

PACING NOTE: wait_time = between(1, 3) is ~0.5 req/s per VU (each task
fires one request, then waits 1–3 s). Real human browsing is 5–30 s between
clicks, so 100 VUs ≈ 500–1500 real visitors in load-equivalent — fine for
relative tier/version comparison, misleading if you read absolute VU counts
as concurrent humans.
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

    @task(8)
    def submit_contact_form(self):
        # Write path: each call → an Umbraco content node creation → ~10-15 SQL
        # inserts (content + version + culture variations + 4 property values).
        # Weight 8 of total ~113 ≈ 7% of traffic — within the realistic 5-15%
        # write share for CMS production traffic. Anonymous JSON endpoint, no
        # anti-forgery token required (the form-encoded form-submit endpoint
        # enforces it; the JSON submit endpoint doesn't).
        payload = {
            "name": "LoadTest VU",
            "email": "loadtest@example.com",
            "subject": "Locust submission",
            "message": "Auto-generated submission from the Umbraco load-test locustfile.",
        }
        self.client.post(
            "/umbraco/api/contactform/submit",
            json=payload,
            name="ContactFormSubmit",
        )
