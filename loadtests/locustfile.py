"""
Smoke-test scaffold. Replace or extend with real HttpUser subclasses (in this
file or in sibling modules — list them in templates/load-test-job.yml's
configurationFiles so Azure Load Testing uploads them with the test plan).
"""

from locust import HttpUser, between, task


class HomepageSmokeUser(HttpUser):
    wait_time = between(1, 3)

    @task
    def homepage(self):
        self.client.get("/", name="Homepage")
