"""
Default scenario: traditional Umbraco customer profile.

Browses rendered pages (homepage, sections, categories, pages, details, media)
and submits the occasional contact form. Models a customer who uses Umbraco's
standard content delivery without the Delivery API.

Weights skew toward Detail (deepest read path, most SQL pressure); homepage
is output-cached and kept low so it doesn't dominate metrics. Total weight
113; write share 8/113 ≈ 7%.
"""

# Locally: locustfile lives in scenarios/<Name>/ but imports _helpers.py from
# loadtests/. Insert the parent's parent on sys.path so the import resolves.
# On Azure Load Testing this is a no-op since ALT flattens all files into one
# engine working dir (helpers land next to the locustfile).
import sys
import pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from locust import FastHttpUser, between, task

from _helpers import pick_url, post_contact_form, register_inventory_probe

register_inventory_probe()


class FrontEndUser(FastHttpUser):
    # ~0.5 req/s per VU. 100 VUs ≈ 500-1500 real visitors in load-equivalent
    # (humans wait 5-30 s between clicks). Fine for relative comparison;
    # do not read VU counts as concurrent humans.
    wait_time = between(1, 3)

    # @task(N) is a relative pick weight - Locust picks per VU by weighted
    # random, so e.g. detail (35) fires 35/113 ≈ 31% of the time. Only the
    # ratios matter; multiplying every weight by 10 changes nothing.

    @task(5)
    def homepage(self):
        self.client.get("/", name="Homepage")

    @task(10)
    def section(self):
        pick_url(self, "section", "Section")

    @task(20)
    def category(self):
        pick_url(self, "category", "Category")

    @task(30)
    def page(self):
        pick_url(self, "page", "Page")

    @task(35)
    def detail(self):
        pick_url(self, "detail", "Detail")

    @task(5)
    def media(self):
        pick_url(self, "media", "Media")

    # Write path - each call creates an Umbraco content node → ~10-15 SQL inserts.
    @task(8)
    def submit_contact_form(self):
        post_contact_form(self)
