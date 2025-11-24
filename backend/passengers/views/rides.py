# passengers/views/rides.py

from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated

from ..permissions import IsPassenger
from passengers.services import ride_services


class PassengerCreateRideRequestView(APIView):
    """
    POST: Passenger creates a ride request.
    """
    permission_classes = [IsAuthenticated, IsPassenger]

    def post(self, request):
        existing = ride_services.check_active_ride(request.user)

        if existing:
            return Response({"error": "You already have an active ride"}, status=400)

        result = ride_services.create_ride_request(
            user=request.user,
            data=request.data,
            request=request
        )

        return Response(result, status=201)


class PassengerCurrentRideView(APIView):
    """
    GET: Passenger polling endpoint to get current ride.
    """
    permission_classes = [IsAuthenticated, IsPassenger]

    def get(self, request):
        result = ride_services.get_current_ride(request.user, request)

        if not result:
            return Response({
                "has_active_ride": False,
                "message": "No active ride found"
            })

        ride = result["ride_obj"]
        serialized = result["serialized"]

        # build response
        resp = {
            "has_active_ride": True,
            "ride": serialized,
            "status": ride.status,
            "driver_assigned": ride.status == "accepted"
        }

        if ride.status == "pending":
            resp["message"] = "Searching for nearby drivers..."
        elif ride.status == "accepted":
            resp["message"] = "Driver is on the way!"
        else:
            resp["message"] = "No drivers available currently."

        return Response(resp)
        

class PassengerCancelRideView(APIView):
    """
    POST: Passenger cancels a ride.
    """
    permission_classes = [IsAuthenticated, IsPassenger]

    def post(self, request, ride_id: int):
        result = ride_services.cancel_ride(
            user=request.user,
            ride_id=ride_id,
            data=request.data
        )

        if result.get("error") == "not_found":
            return Response({"error": "Ride not found"}, status=404)

        if result.get("error") == "cannot_cancel":
            return Response(
                {"error": "Cannot cancel this ride", "status": result["status"]},
                status=400
            )

        return Response(result)
