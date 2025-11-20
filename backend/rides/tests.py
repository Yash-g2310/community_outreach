from datetime import timedelta

from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIRequestFactory, force_authenticate
from unittest.mock import patch

from .models import DriverProfile, RideOffer, RideRequest, User
from .views import accept_ride, reject_ride_offer


class RideOfferFlowTests(TestCase):
	def setUp(self):
		self.factory = APIRequestFactory()
		self.passenger = User.objects.create_user(
			username='passenger',
			password='pass1234',
			role='user',
			phone_number='9000000000'
		)
		self.driver_one = User.objects.create_user(
			username='driver_one',
			password='driver1234',
			role='driver',
			phone_number='9000000001'
		)
		self.driver_two = User.objects.create_user(
			username='driver_two',
			password='driver1234',
			role='driver',
			phone_number='9000000002'
		)

		DriverProfile.objects.create(
			user=self.driver_one,
			vehicle_number='WB-1001',
			status='available',
			current_latitude=28.6139,
			current_longitude=77.2090
		)
		DriverProfile.objects.create(
			user=self.driver_two,
			vehicle_number='WB-1002',
			status='available',
			current_latitude=28.6140,
			current_longitude=77.2095
		)

		self.ride = RideRequest.objects.create(
			passenger=self.passenger,
			pickup_latitude=28.6139,
			pickup_longitude=77.2090,
			pickup_address='Connaught Place',
			dropoff_address='India Gate',
			number_of_passengers=1,
			broadcast_radius=500,
			status='pending'
		)

		self.offer_one = RideOffer.objects.create(
			ride=self.ride,
			driver=self.driver_one,
			order=0,
			status='pending',
			sent_at=timezone.now()
		)
		self.offer_two = RideOffer.objects.create(
			ride=self.ride,
			driver=self.driver_two,
			order=1,
			status='pending'
		)

	def test_accept_ride_updates_offer_ledger(self):
		request = self.factory.post('/handle/%d/accept/' % self.ride.id)
		force_authenticate(request, user=self.driver_one)
		response = accept_ride(request, ride_id=self.ride.id)

		self.assertEqual(response.status_code, 200)

		self.ride.refresh_from_db()
		self.offer_one.refresh_from_db()
		self.offer_two.refresh_from_db()
		self.driver_one.driver_profile.refresh_from_db()

		self.assertEqual(self.ride.status, 'accepted')
		self.assertEqual(self.ride.driver, self.driver_one)
		self.assertEqual(self.offer_one.status, 'accepted')
		self.assertEqual(self.offer_two.status, 'expired')
		self.assertEqual(self.driver_one.driver_profile.status, 'busy')

	@patch('rides.views.dispatch_next_offer', return_value=False)
	def test_reject_offer_marks_no_drivers_when_queue_empty(self, mock_dispatch):
		# Only keep first offer active to simulate end of queue
		self.offer_two.delete()

		request = self.factory.post('/handle/%d/reject/' % self.ride.id)
		force_authenticate(request, user=self.driver_one)
		response = reject_ride_offer(request, ride_id=self.ride.id)

		self.assertEqual(response.status_code, 200)
		mock_dispatch.assert_called_once()

		self.ride.refresh_from_db()
		self.offer_one.refresh_from_db()

		self.assertEqual(self.offer_one.status, 'rejected')
		self.assertEqual(self.ride.status, 'no_drivers')

	@patch('rides.views.dispatch_next_offer', return_value=True)
	def test_reject_offer_triggers_next_driver(self, mock_dispatch):
		request = self.factory.post('/handle/%d/reject/' % self.ride.id)
		force_authenticate(request, user=self.driver_one)
		response = reject_ride_offer(request, ride_id=self.ride.id)

		self.assertEqual(response.status_code, 200)
		mock_dispatch.assert_called_once()

		self.offer_one.refresh_from_db()
		self.ride.refresh_from_db()

		self.assertEqual(self.offer_one.status, 'rejected')
		self.assertEqual(self.ride.status, 'pending')

	def test_process_offer_timeouts_expires_and_dispatches(self):
		self.offer_one.sent_at = timezone.now() - timedelta(seconds=15)
		self.offer_one.save(update_fields=['sent_at'])

		call_command('process_offer_timeouts', timeout=10)

		self.offer_one.refresh_from_db()
		self.offer_two.refresh_from_db()
		self.ride.refresh_from_db()

		self.assertEqual(self.offer_one.status, 'expired')
		self.assertIsNotNone(self.offer_one.responded_at)
		self.assertIsNotNone(self.offer_two.sent_at)
		self.assertEqual(self.ride.status, 'pending')
