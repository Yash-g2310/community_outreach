from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from ..permissions import IsPassenger
from ..serializers import RequestLocationSerializer
from ..services import info_services


class PassengerProfileView(APIView):
    """
    GET  -> Retrieve authenticated passenger profile
    POST -> Partially update passenger profile
    """
    permission_classes = [IsAuthenticated, IsPassenger]

    def get(self, request):
        data = info_services.get_passenger_profile(request.user)
        return Response(data)

    def post(self, request):
        data = info_services.update_passenger_profile(request.user, request.data, request)
        return Response(data)


class PassengerNearbyDriversView(APIView):
    """
    POST: Returns nearby drivers for passenger location input.
    """
    permission_classes = [IsAuthenticated, IsPassenger]

    def post(self, request):
        loc_ser = RequestLocationSerializer(data=request.data)
        loc_ser.is_valid(raise_exception=True)

        lat = loc_ser.validated_data["latitude"]
        lon = loc_ser.validated_data["longitude"]
        radius = int(request.data.get("radius", 1000))

        nearby = info_services.find_nearby_drivers(lat, lon, radius)

        return Response({
            "count": len(nearby),
            "drivers": nearby,
            "search_radius_meters": radius,
        })


class PassengerRideHistoryView(APIView):
    """
    GET: Retrieve passenger ride history (completed + cancelled)
    """
    permission_classes = [IsAuthenticated, IsPassenger]

    def get(self, request):
        history = info_services.get_passenger_ride_history(request.user)
        return Response({"count": len(history), "rides": history})
