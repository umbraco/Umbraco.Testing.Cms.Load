"""
DeliveryApi scenario: headless Umbraco customer profile.

Hits the Content Delivery API (list + item-by-id), plus media (which a
headless frontend still loads from Umbraco for assets), plus the occasional
write back to Umbraco. No rendered-page traffic - real headless customers
run a separate frontend (Next.js / Astro / etc.) that consumes the API; the
rendered Umbraco URLs either don't exist or aren't user-facing in production.

Weights: delivery_item dominates because each frontend page render typically
fetches one item by id. delivery_list models occasional pagination. Media is
supporting traffic (one or two images per rendered page). Writes are rare
but exercised so SQL-write contention is on the radar.
Total weight 48; write share 8/48 ≈ 17% (high - bring down once more write
tasks land beyond just contact form).
"""

# Locally: locustfile lives in scenarios/<Name>/ but imports _helpers.py from
# loadtests/. Insert the parent's parent on sys.path so the import resolves.
# On Azure Load Testing this is a no-op since ALT flattens all files into one
# engine working dir (helpers land next to the locustfile).
import sys
import pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

import random

from locust import FastHttpUser, between, task

from _helpers import (
    DELIVERY_API_LIST_PATH,
    pick_url,
    register_delivery_api_probe,
    register_inventory_probe,
)

# Inventory probe is needed for the media bucket; delivery probe seeds the
# ids list for delivery_item. Both must succeed or the relevant tasks fail.
register_inventory_probe()
register_delivery_api_probe()


class FrontEndUser(FastHttpUser):
    wait_time = between(1, 3)

    # @task(N) is a relative pick weight - Locust picks per VU by weighted
    # random, so e.g. delivery_item (25) fires 25/48 ≈ 52% of the time. Only
    # the ratios matter; multiplying every weight by 10 changes nothing.

    @task(10)
    def delivery_list(self):
        skip = random.randint(0, 5) * 20
        self.client.get(
            f"{DELIVERY_API_LIST_PATH}?skip={skip}&take=20",
            name="DeliveryApiList",
        )

    @task(25)
    def delivery_item(self):
        ids = self.environment.delivery_ids
        if not ids:
            raise RuntimeError("Delivery API probe returned zero items - scenario misconfigured")
        self.client.get(
            f"{DELIVERY_API_LIST_PATH}/item/{random.choice(ids)}",
            name="DeliveryApiItem",
        )

    @task(5)
    def media(self):
        pick_url(self, "media", "Media")

    # Write path - each call creates an Umbraco content node → ~10-15 SQL inserts.
    @task(8)
    def submit_contact_form(self):
        self.client.post(
            "/umbraco/api/contactform/submit",
            json={
                "name": "LoadTest VU",
                "email": "loadtest@example.com",
                "subject": "Locust submission",
                "message": "Auto-generated submission from the Umbraco load-test locustfile.",
            },
            name="ContactFormSubmit",
        )
