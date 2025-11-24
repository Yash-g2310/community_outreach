from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from drivers.models import DriverProfile
from drivers.serializers import (
    DriverProfileSerializer,
    DriverStatusSerializer,
    LocationUpdateSerializer,
)
from rides.serializers import RideRequestSerializer
from rides.models import RideRequest

from drivers import services

# Utility: Ensure request.user is a driver
def require_driver(user):
    if user.role != "driver":
        return False, Response({"error": "Only drivers allowed"}, status=403)
    try:
        profile = user.driver_profile
        return True, profile
    except DriverProfile.DoesNotExist:
        return False, Response({"error": "Driver profile not found"}, status=404)


class DriverProfileView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        ok, profile = require_driver(request.user)
        if ok is False:
            return profile  # Response object

        serializer = DriverProfileSerializer(profile, context={"request": request})
        return Response(serializer.data)

    def post(self, request):
        ok, profile = require_driver(request.user)
        if ok is False:
            return profile

        vehicle_number = request.data.get("vehicle_number", profile.vehicle_number)
        profile.vehicle_number = vehicle_number
        profile.save(update_fields=["vehicle_number"])

        serializer = DriverProfileSerializer(profile, context={"request": request})
        return Response(serializer.data, status=200)


#    NOTE: WS can replace this in future, but HTTP fallback remains.
class DriverStatusView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        ok, profile = require_driver(request.user)
        if ok is False:
            return profile

        return Response({"status": profile.status})

    def put(self, request):
        ok, profile = require_driver(request.user)
        if ok is False:
            return profile

        serializer = DriverStatusSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        new_status = serializer.validated_data["status"]

        services.update_driver_status(profile, new_status)

        return Response({
            "message": f"Status updated to {new_status}",
            "status": new_status
        })


#    A candidate to move fully to WS. Keep HTTP fallback.
class DriverLocationUpdateView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        ok, profile = require_driver(request.user)
        if ok is False:
            return profile

        return Response({
            "latitude": float(profile.current_latitude) if profile.current_latitude else None,
            "longitude": float(profile.current_longitude) if profile.current_longitude else None,
            "last_updated": profile.last_location_update,
            "status": profile.status,
        })

    def post(self, request):
        ok, profile = require_driver(request.user)
        if ok is False:
            return profile

        serializer = LocationUpdateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        lat = serializer.validated_data["latitude"]
        lon = serializer.validated_data["longitude"]

        services.update_driver_location(profile, lat, lon)

        return Response({
            "message": "Location updated",
            "latitude": float(lat),
            "longitude": float(lon),
            "status": profile.status
        })


#    Future: Replaced by WS-based push offers.
class NearbyRidesForDriverView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        ok, profile = require_driver(request.user)
        if ok is False:
            return profile

        # If not available, return empty
        if profile.status != "available":
            return Response({
                "rides": [],
                "count": 0,
                "message": "Set status to 'available' to receive ride requests."
            })

        serializer = LocationUpdateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        lat = serializer.validated_data["latitude"]
        lon = serializer.validated_data["longitude"]

        rides = services.find_nearby_pending_rides(lat, lon)
        serialized = RideRequestSerializer(rides, many=True, context={"request": request})

        return Response({"rides": serialized.data, "count": len(serialized.data)})


class DriverCurrentRideView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        ok, profile = require_driver(request.user)
        if ok is False:
            return profile

        ride = RideRequest.objects.filter(driver=request.user, status="accepted").first()
        if not ride:
            return Response({"message": "No active ride"}, status=404)

        serializer = RideRequestSerializer(ride, context={"request": request})
        return Response(serializer.data)


class DriverRideHistoryView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        ok, profile = require_driver(request.user)
        if ok is False:
            return profile

        completed = RideRequest.objects.filter(driver=request.user, status="completed")
        serializer = RideRequestSerializer(completed, many=True, context={"request": request})

        return Response({"count": completed.count(), "rides": serializer.data})
