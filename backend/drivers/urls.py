from django.urls import path
from .views import (
    DriverProfileView,
    DriverStatusView,
    DriverLocationUpdateView,
    NearbyRidesForDriverView,
    DriverCurrentRideView,
    DriverRideHistoryView,
)

urlpatterns = [
    path("profile/", DriverProfileView.as_view(), name="driver-profile"),
    path("status/", DriverStatusView.as_view(), name="driver-status"),
    path("location/", DriverLocationUpdateView.as_view(), name="driver-location"),
    path("nearby-rides/", NearbyRidesForDriverView.as_view(), name="driver-nearby-rides"),
    path("current-ride/", DriverCurrentRideView.as_view(), name="driver-current-ride"),
    path("history/", DriverRideHistoryView.as_view(), name="driver-history"),
]
