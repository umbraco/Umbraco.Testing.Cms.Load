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
overlay disabled it), bucket-dependent tasks raise (visible as 100%-error
samplers in the run). Loud failure beats silent homepage-only fallback —
a misconfigured seeder is something you want to see, not something that
quietly produces "successful" runs with the wrong traffic shape.

The locustfile also probes the Umbraco Content Delivery API at start.
If it responds (i.e. the scenario overlay enabled it — see DeliveryApi
scenario), Delivery API tasks are spliced into the workload so headless
performance is measured alongside MVC delivery. If the API is off
(default), no Delivery API tasks fire — keeps non-headless scenarios'
metrics clean.

PACING NOTE: wait_time = between(1, 3) is ~0.5 req/s per VU (each task
fires one request, then waits 1–3 s). Real human browsing is 5–30 s between
clicks, so 100 VUs ≈ 500–1500 real visitors in load-equivalent — fine for
relative tier/version comparison, misleading if you read absolute VU counts
as concurrent humans.
"""

import logging
import random
import uuid

import requests
from locust import FastHttpUser, between, events, task

logger = logging.getLogger(__name__)

INVENTORY_PATH = "/umbraco/api/seederstatus/inventory"
INVENTORY_TIMEOUT_SEC = 15

DELIVERY_API_LIST_PATH = "/umbraco/delivery/api/v2/content"
DELIVERY_API_PROBE_TIMEOUT_SEC = 10


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
    except (requests.RequestException, ValueError) as ex:
        # Buckets stay empty; _hit then raises per-call so the run shows up
        # as 100%-error on the affected tasks rather than silently homepage-only.
        logger.error(f"Inventory fetch failed ({ex}); bucket-dependent tasks will fail")
        return

    if not isinstance(data, dict):
        logger.error(f"Inventory endpoint returned non-object JSON ({type(data).__name__}); bucket-dependent tasks will fail")
        return

    # Defensive filter: each sample should be a dict with 'url' and 'docType' but
    # we don't trust the API to be perfectly shaped (a single bad item would crash
    # the listener and skip workload setup for every VU in this engine).
    samples = [s for s in data.get("sampleContentUrls", []) if isinstance(s, dict) and "url" in s]
    environment.inventory = {
        "section":  [u for u in data.get("rootSectionUrls", []) if isinstance(u, str)],
        "category": [s["url"] for s in samples if s.get("docType") == "Category"],
        "page":     [s["url"] for s in samples if s.get("docType") == "Page"],
        "detail":   [s["url"] for s in samples if s.get("docType") == "Detail"],
        "media":    [u for u in data.get("sampleMediaUrls", []) if isinstance(u, str)],
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
        """Pick a random URL from a pre-built bucket. Raises on empty bucket so a failed
        inventory probe / unseeded scenario surfaces loudly instead of silently shifting
        all traffic to the homepage."""
        urls = self.environment.inventory.get(bucket)
        if not urls:
            raise RuntimeError(f"Bucket '{bucket}' is empty — inventory probe failed or seeder didn't seed it")
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
        #
        # Randomise the email per call so DB unique-constraints (if added by
        # the site) and SQL Server's plan/page cache can't short-circuit the
        # write path — an identical payload every call masks real insert
        # pressure and undercounts the tier-differentiating SQL load.
        token = uuid.uuid4().hex
        payload = {
            "name": f"LoadTest VU {token[:8]}",
            "email": f"loadtest+{token}@example.com",
            "subject": f"Locust submission {token[:8]}",
            "message": "Auto-generated submission from the Umbraco load-test locustfile.",
        }
        # catch_response so a 200 OK body carrying validation errors
        # (e.g. {"success": false, "errors": [...]}) isn't silently counted
        # as a successful write. The endpoint normally returns either a JSON
        # success payload or a 4xx — anything else (including 2xx with an
        # error body) is treated as a failure.
        with self.client.post(
            "/umbraco/api/contactform/submit",
            json=payload,
            name="ContactFormSubmit",
            catch_response=True,
        ) as response:
            if response.status_code >= 400:
                response.failure(f"HTTP {response.status_code}")
                return
            try:
                body = response.json()
            except ValueError:
                # Some Umbraco builds return an empty 200 on success; only
                # mark failure when there *is* a body and it's not JSON.
                if response.text:
                    response.failure("non-JSON body")
                return
            # Heuristic match against common Umbraco/form-builder shapes.
            if isinstance(body, dict):
                if body.get("success") is False:
                    response.failure(f"success=false: {body.get('errors') or body}")
                    return
                errors = body.get("errors") or body.get("Errors")
                if errors:
                    response.failure(f"errors in body: {errors}")
                    return


# Delivery API tasks — registered on the user class only when the API is reachable
# (see configure_delivery_api below). Defined as plain functions, not @task methods,
# so they're invisible to Locust until spliced into CmsBrowsingUser.tasks at runtime.
def _delivery_list(user):
    """Paginated list — exercises the index + serialiser hot path."""
    skip = random.randint(0, 5) * 20
    user.client.get(
        f"{DELIVERY_API_LIST_PATH}?skip={skip}&take=20",
        name="DeliveryApiList",
    )


def _delivery_item(user):
    """Fetch a single item by id — closest Delivery-API analogue to the Detail task."""
    items = user.environment.delivery_inventory.get("ids", [])
    if not items:
        # Inventory probed empty — fall through to a cheap list call so the task
        # doesn't no-op (which would shrink the effective workload).
        user.client.get(
            f"{DELIVERY_API_LIST_PATH}?take=1",
            name="DeliveryApiList (fallback)",
        )
        return
    item_id = random.choice(items)
    user.client.get(
        f"{DELIVERY_API_LIST_PATH}/item/{item_id}",
        name="DeliveryApiItem",
    )


@events.test_start.add_listener
def configure_delivery_api(environment, **_):
    """Probe the Delivery API; if reachable, splice its tasks into the workload.

    Pages through the full set (in 100-item batches up to a safety cap) so
    _delivery_item picks from every seeded item, not a 50-item slice that would
    sit hot in cache and make the test measure cache lookup rather than query
    work. The safety cap is in place so a future seeder bug yielding millions
    of items doesn't stall test_start.
    """
    PAGE_SIZE = 100
    MAX_ITEMS = 5000   # safety cap; current Massive preset is ~10k docs

    environment.delivery_inventory = {"ids": []}
    if not environment.host:
        return

    base = environment.host.rstrip("/") + DELIVERY_API_LIST_PATH
    ids = []
    skip = 0
    while len(ids) < MAX_ITEMS:
        try:
            response = requests.get(
                f"{base}?skip={skip}&take={PAGE_SIZE}",
                timeout=DELIVERY_API_PROBE_TIMEOUT_SEC,
            )
        except requests.RequestException as ex:
            logger.info(f"Delivery API probe failed at skip={skip} ({ex}); Delivery API tasks disabled")
            break

        if response.status_code != 200:
            if skip == 0:
                logger.info(
                    f"Delivery API probe returned {response.status_code}; "
                    f"Delivery API tasks disabled (expected for non-DeliveryApi scenarios)"
                )
            else:
                # Mid-pagination failure is unexpected — surface it so a partial
                # inventory doesn't silently shrink the workload coverage.
                logger.warning(
                    f"Delivery API probe at skip={skip} returned {response.status_code}; "
                    f"truncating inventory at {len(ids)} item(s)"
                )
            break

        try:
            body = response.json()
        except ValueError:
            logger.warning(f"Delivery API probe at skip={skip} returned 200 but body was not JSON")
            break

        if not isinstance(body, dict):
            logger.warning(f"Delivery API probe at skip={skip} returned non-object JSON ({type(body).__name__})")
            break

        page = [item["id"] for item in body.get("items", []) if isinstance(item, dict) and "id" in item]
        if not page:
            break  # ran past the end
        ids.extend(page)
        if len(page) < PAGE_SIZE:
            break  # last page
        skip += PAGE_SIZE

    if not ids:
        return
    environment.delivery_inventory = {"ids": ids}

    # Mutating CmsBrowsingUser.tasks at test_start is safe: Locust resolves the
    # tasks attribute per-instance at task-pick time, not at class definition,
    # and test_start fires before any VU is spawned. Weights: list=10, item=25
    # — together ~24% of the ~141-weight total, so Delivery API gets a
    # meaningful share without dominating the MVC mix.
    extra = [_delivery_list] * 10 + [_delivery_item] * 25
    CmsBrowsingUser.tasks = list(CmsBrowsingUser.tasks) + extra

    logger.info(
        f"Delivery API enabled: inventory={len(ids)} items, "
        f"spliced {len(extra)} weighted tasks into workload"
    )
