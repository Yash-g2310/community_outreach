from django.db import models
from django.conf import settings

class RideRequest(models.Model):
    """Simplified ride request model for polling-based notifications"""

    STATUS_CHOICES = [
        ('pending', 'Pending'),
        ('accepted', 'Accepted'),
        ('no_drivers', 'No Drivers Available'),
        ('completed', 'Completed'),
        ('cancelled_user', 'Cancelled by User'),
        ('cancelled_driver', 'Cancelled by Driver'),
    ]

    # Foreign keys
    passenger = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='ride_requests'
    )

    driver = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='accepted_rides'
    )

    # Pickup location
    pickup_latitude = models.DecimalField(max_digits=9, decimal_places=6)
    pickup_longitude = models.DecimalField(max_digits=9, decimal_places=6)
    pickup_address = models.TextField(null=True, blank=True)

    # Dropoff location
    dropoff_address = models.TextField(null=True, blank=True)

    # Passenger count
    number_of_passengers = models.IntegerField(default=1)

    # Status & searching radius
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='pending')
    broadcast_radius = models.IntegerField(default=1000)

    # Timestamps
    requested_at = models.DateTimeField(auto_now_add=True)
    accepted_at = models.DateTimeField(null=True, blank=True)
    completed_at = models.DateTimeField(null=True, blank=True)
    cancelled_at = models.DateTimeField(null=True, blank=True)

    cancellation_reason = models.TextField(null=True, blank=True)

    class Meta:
        db_table = 'ride_requests'
        ordering = ['-requested_at']

    def __str__(self):
        return f"Ride #{self.id} - {self.passenger} - {self.status}"


class RideOffer(models.Model):
    """Tracks which drivers were offered the ride (Daisy Chain / matching queue)."""

    ride = models.ForeignKey(
        RideRequest,
        on_delete=models.CASCADE,
        related_name='offers'
    )

    driver = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        limit_choices_to={'role': 'driver'}
    )

    order = models.PositiveIntegerField()  # 0 = closest driver

    status = models.CharField(
        max_length=20,
        choices=[
            ('pending', 'Pending'),
            ('accepted', 'Accepted'),
            ('rejected', 'Rejected'),
            ('expired', 'Expired'),
        ],
        default='pending',
    )

    sent_at = models.DateTimeField(null=True, blank=True)
    responded_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ['order']
        constraints = [
            models.UniqueConstraint(
                fields=['ride', 'driver'],
                name='unique_ride_driver'
            )
        ]

    def __str__(self):
        return f"Offer #{self.id} - Ride {self.ride.id} -> Driver {self.driver}"
