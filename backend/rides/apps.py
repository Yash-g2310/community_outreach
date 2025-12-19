"""Rides app configuration."""

from django.apps import AppConfig


class RidesConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'rides'

    def ready(self):
        # Note: Offer timeouts are now handled by Celery tasks (see tasks.py)
        # The old threading-based monitor has been deprecated.
        pass
