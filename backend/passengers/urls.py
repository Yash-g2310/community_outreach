# passengers/urls.py

from django.urls import path

from .views.info import (
    PassengerProfileView,
    PassengerNearbyDriversView,
    PassengerRideHistoryView,
)

from .views.rides import (
    PassengerCreateRideRequestView,
    PassengerCurrentRideView,
    PassengerCancelRideView,
)

app_name = "passengers"

urlpatterns = [
    # INFO
    path("profile/", PassengerProfileView.as_view(), name="profile"),
    path("nearby-drivers/", PassengerNearbyDriversView.as_view(), name="nearby-drivers"),
    path("history/", PassengerRideHistoryView.as_view(), name="ride-history"),

    # RIDE
    path("request/", PassengerCreateRideRequestView.as_view(), name="create-ride"),
    path("current/", PassengerCurrentRideView.as_view(), name="current-ride"),
    path("<int:ride_id>/cancel/", PassengerCancelRideView.as_view(), name="cancel-ride"),
]
