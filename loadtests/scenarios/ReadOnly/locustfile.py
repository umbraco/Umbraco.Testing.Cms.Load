"""
ReadOnly scenario: the Default scenario's read traffic with the contact-form
submit left out. A diagnostic, not a benchmark.

Default runs show whole-site pauses and short slow spells. Its only write is
the contact form, which saves a new content node on every submit (about 7% of
requests). Queue this scenario on the same version and tiers as a Default run
that paused: if the pauses and slow spells are gone, the writes cause them; if
they are still there, they do not. Keep the read tasks and their weights
identical to scenarios/Default/locustfile.py - the missing write must be the
only difference.

Total weight 105, all reads.
"""

# Locally: locustfile lives in scenarios/<Name>/ but imports _helpers.py from
# loadtests/. Insert the parent's parent on sys.path so the import resolves.
# On Azure Load Testing this is a no-op since ALT flattens all files into one
# engine working dir (helpers land next to the locustfile).
import sys
import pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from locust import FastHttpUser, between, task

from _helpers import pick_url, register_inventory_probe

register_inventory_probe()


class FrontEndUser(FastHttpUser):
    # Same pacing as Default: ~0.5 req/s per VU.
    wait_time = between(1, 3)

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
