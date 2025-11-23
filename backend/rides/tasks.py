from celery import shared_task
from django.utils import timezone
from rides.models import RideOffer

@shared_task
def expire_ride_offer_task(offer_id):
    try:
        offer = RideOffer.objects.get(id=offer_id)
        # Only expire if still pending and not responded
        if offer.status == 'pending' and offer.responded_at is None:
            from rides.notifications import expire_offer_and_dispatch
            expire_offer_and_dispatch(offer)
    except RideOffer.DoesNotExist:
        pass
