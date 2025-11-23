from django.core.management.base import BaseCommand
from django.utils import timezone
from datetime import timedelta
from rides.models import RideOffer, RideRequest
import logging

logger = logging.getLogger(__name__)


class Command(BaseCommand):
    help = "Clean up old ride offers and completed/cancelled rides."

    def add_arguments(self, parser):
        parser.add_argument(
            "--days",
            type=int,
            default=30,
            help="Delete offers older than this many days (default: 30).",
        )
        parser.add_argument(
            "--dry-run",
            action="store_true",
            help="Show what would be deleted without actually deleting.",
        )

    def handle(self, *args, **options):
        days = options["days"]
        dry_run = options["dry_run"]
        cutoff = timezone.now() - timedelta(days=days)

        # Clean up old offers
        old_offers = RideOffer.objects.filter(sent_at__lt=cutoff)
        offers_count = old_offers.count()

        # Clean up old completed/cancelled rides
        old_rides = RideRequest.objects.filter(
            created_at__lt=cutoff,
            status__in=['completed', 'cancelled_user', 'cancelled_driver', 'no_drivers']
        )
        rides_count = old_rides.count()

        if dry_run:
            self.stdout.write(
                self.style.WARNING(
                    f"DRY RUN: Would delete {offers_count} offers and {rides_count} old rides older than {days} days."
                )
            )
        else:
            old_offers.delete()
            old_rides.delete()
            logger.info(f"Cleaned up {offers_count} old offers and {rides_count} old rides")
            self.stdout.write(
                self.style.SUCCESS(
                    f"Deleted {offers_count} old offers and {rides_count} old rides older than {days} days."
                )
            )