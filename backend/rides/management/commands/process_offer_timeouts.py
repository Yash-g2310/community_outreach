from django.core.management.base import BaseCommand
from rides.services.offer_timeout import process_offer_timeouts


class Command(BaseCommand):
    help = "Expire ride offers that have been waiting too long and notify the next driver."

    def add_arguments(self, parser):
        parser.add_argument(
            "--timeout",
            type=int,
            default=10,
            help="Timeout in seconds before an offer automatically expires (default: 10).",
        )

    def handle(self, *args, **options):
        timeout = options["timeout"]
        expired_count, dispatched_count = process_offer_timeouts(timeout_seconds=timeout)

        self.stdout.write(
            self.style.SUCCESS(
                f"Expired {expired_count} offer(s); dispatched next driver for {dispatched_count} ride(s)."
            )
        )
