"""Celery tasks for ride-related background processing."""

from celery import shared_task
from django.utils import timezone
import logging

logger = logging.getLogger(__name__)


@shared_task
def test_task():
    """Simple test task to verify Celery is working."""
    print("Celery is working!!")
    return True


@shared_task
def expire_ride_offer_task(offer_id: int):
    """
    Celery task to expire a ride offer after timeout.
    
    This task is scheduled when an offer is sent to a driver.
    If the driver hasn't responded, the offer is expired and
    the next driver in the queue is notified.
    """
    from rides.models import RideOffer
    
    try:
        offer = RideOffer.objects.get(id=offer_id)
        
        # Only expire if still pending and not responded
        if offer.status == 'pending' and offer.responded_at is None:
            logger.info(f"Expiring ride offer {offer_id} for ride {offer.ride_id}")
            
            # Use services layer for expiry logic
            from services.matching import expire_offer_and_dispatch
            expire_offer_and_dispatch(offer)
        else:
            logger.info(f"Offer {offer_id} already responded or not pending (status: {offer.status})")
            
    except RideOffer.DoesNotExist:
        logger.warning(f"Offer {offer_id} not found for expiry task")
    except Exception as e:
        logger.error(f"Error expiring offer {offer_id}: {e}")
