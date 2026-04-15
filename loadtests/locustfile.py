"""
Umbraco CMS Load Test — Entry Point

Currently contains a single smoke-test User that hits the homepage. This is
intentionally minimal: it proves the whole pipeline is wired up end-to-end
(provisioning -> deploy -> seed -> ALT engine -> results upload) without
prescribing any particular test scenarios.

Add real scenarios as separate HttpUser subclasses here or in sibling modules
imported from this file. When you add modules, list them in the
`configurationFiles:` section of templates/load-test-job.yml so ALT uploads
them to the test engines alongside the test plan.

Runs on Azure Load Testing via AzureLoadTest@1. Locust executes on dedicated
ALT engine VMs, not on the pipeline agent.
"""

from locust import HttpUser, between, task


class HomepageSmokeUser(HttpUser):
    """Hits the homepage. Replace or extend with real scenarios."""

    wait_time = between(1, 3)

    @task
    def homepage(self):
        self.client.get("/", name="Homepage")
