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
import uuid
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
            # Buckets stay empty; pick_url then raises per-call so the run shows up
            # as 100%-error on the affected tasks rather than silently homepage-only.
            logger.error(f"Inventory unreachable ({ex}); workload tasks will fail")
            return

        if not isinstance(data, dict):
            logger.error(f"Inventory returned non-object JSON ({type(data).__name__}); workload tasks will fail")
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
    """Probe the Delivery API at test start. On 200 seed environment.delivery_ids.

    Pages through the full set (in 100-item batches up to a safety cap) so
    delivery_item picks from every seeded item, not a 50-item slice that would
    sit hot in cache and make the test measure cache lookup rather than query
    work. The safety cap is in place so a future seeder bug yielding millions
    of items doesn't stall test_start.
    """
    PAGE_SIZE = 100
    MAX_ITEMS = 5000   # safety cap; current Massive preset is ~10k docs

    @events.test_start.add_listener
    def _on_start(environment, **_):
        environment.delivery_ids = []
        if not environment.host:
            return

        base = environment.host.rstrip("/") + DELIVERY_API_LIST_PATH
        ids = []
        skip = 0
        while len(ids) < MAX_ITEMS:
            try:
                response = requests.get(f"{base}?skip={skip}&take={PAGE_SIZE}", timeout=10)
            except requests.RequestException as ex:
                logger.warning(f"Delivery API probe failed at skip={skip} ({ex})")
                break

            if response.status_code != 200:
                if skip == 0:
                    logger.warning(f"Delivery API probe returned {response.status_code} (expected 200 in this scenario)")
                break

            try:
                body = response.json()
            except ValueError:
                logger.warning(f"Delivery API probe returned 200 at skip={skip} but body was not JSON")
                break

            if not isinstance(body, dict):
                break

            page = [i["id"] for i in body.get("items", []) if isinstance(i, dict) and "id" in i]
            if not page:
                break  # ran past the end
            ids.extend(page)
            if len(page) < PAGE_SIZE:
                break  # last page
            skip += PAGE_SIZE

        environment.delivery_ids = ids
        logger.info(f"Delivery API enabled: {len(ids)} items inventoried")


def pick_url(user, bucket: str, name: str) -> None:
    """Pick a random URL from a probed bucket. Raises on empty bucket."""
    urls = user.environment.urls.get(bucket)
    if not urls:
        raise RuntimeError(f"Bucket '{bucket}' is empty - inventory probe failed or seeder didn't seed it")
    user.client.get(random.choice(urls), name=name)


def post_contact_form(user, name: str = "ContactFormSubmit") -> None:
    """Submit a contact form with a randomised payload, asserting on the body.

    Per-call uuid so DB unique-constraints (if added) and SQL Server's plan/page
    cache can't short-circuit the write path — an identical payload every call
    masks real insert pressure and undercounts the tier-differentiating SQL load.

    catch_response so a 200 OK carrying validation errors (e.g. {"success":
    false, "errors": [...]}) isn't silently counted as a successful write. The
    endpoint normally returns either a JSON success payload or a 4xx — anything
    else (including 2xx with an error body) is treated as a failure.
    """
    token = uuid.uuid4().hex
    payload = {
        "name": f"LoadTest VU {token[:8]}",
        "email": f"loadtest+{token}@example.com",
        "subject": f"Locust submission {token[:8]}",
        "message": "Auto-generated submission from the Umbraco load-test locustfile.",
    }
    with user.client.post(
        "/umbraco/api/contactform/submit",
        json=payload,
        name=name,
        catch_response=True,
    ) as response:
        if response.status_code >= 400:
            response.failure(f"HTTP {response.status_code}")
            return
        try:
            body = response.json()
        except ValueError:
            if response.text:
                response.failure("non-JSON body")
            return
        if isinstance(body, dict):
            if body.get("success") is False:
                response.failure(f"success=false: {body.get('errors') or body}")
                return
            errors = body.get("errors") or body.get("Errors")
            if errors:
                response.failure(f"errors in body: {errors}")
