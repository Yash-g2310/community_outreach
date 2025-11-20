from django.apps import AppConfig


class RidesConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'rides'

    def ready(self):
        from .offer_timeout_monitor import start_offer_timeout_monitor

        start_offer_timeout_monitor()
