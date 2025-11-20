from rest_framework import status
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework_simplejwt.authentication import JWTAuthentication
from rest_framework_simplejwt.tokens import RefreshToken
from django.contrib.auth import authenticate, login as django_login
from django.middleware.csrf import get_token
from .auth_serializers import LoginSerializer, RegisterSerializer
from .serializers import UserSerializer


class RegisterView(APIView):
    """
    Register a new user (passenger or driver)
    
    POST Body:
    {
        "username": "john_doe",
        "email": "john@example.com",
        "password": "password123",
        "role": "user",  // or "driver"
        "phone_number": "+1234567890",
        "vehicle_number": "DL-1234"  // required for drivers
    }
    """
    permission_classes = (AllowAny,)
    authentication_classes = []
    
    def post(self, request):
        serializer = RegisterSerializer(data=request.data)
        if serializer.is_valid():
            user = serializer.save()
            
            # Generate JWT tokens
            refresh = RefreshToken.for_user(user)
            
            return Response({
                'message': 'User registered successfully',
                'user': UserSerializer(user).data,
                'tokens': {
                    'refresh': str(refresh),
                    'access': str(refresh.access_token),
                }
            }, status=status.HTTP_201_CREATED)
        
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


class LoginView(APIView):
    """
    Login with username and password to get JWT tokens
    
    POST Body:
    {
        "username": "john_doe",
        "password": "password123"
    }
    """
    permission_classes = (AllowAny,)
    authentication_classes = []
    
    def post(self, request):
        serializer = LoginSerializer(data=request.data)
        if serializer.is_valid():
            username = serializer.validated_data['username']
            password = serializer.validated_data['password']
            
            user = authenticate(username=username, password=password)
            
            if user is None:
                return Response(
                    {'error': 'Invalid username or password'},
                    status=status.HTTP_401_UNAUTHORIZED
                )
            
            # Create session for browsable API
            django_login(request, user)
            
            # Generate JWT tokens
            refresh = RefreshToken.for_user(user)
            
            return Response({
                'message': 'Login successful',
                'user': UserSerializer(user).data,
                'tokens': {
                    'refresh': str(refresh),
                    'access': str(refresh.access_token),
                }
            })
        
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)


class RefreshTokenView(APIView):
    """
    Refresh JWT access token
    
    POST Body:
    {
        "refresh": "your_refresh_token"
    }
    """
    permission_classes = (AllowAny,)
    authentication_classes = []
    
    def post(self, request):
        refresh_token = request.data.get('refresh')
        
        if not refresh_token:
            return Response(
                {'error': 'Refresh token is required'},
                status=status.HTTP_400_BAD_REQUEST
            )
        
        try:
            refresh = RefreshToken(refresh_token)
            return Response({
                'access': str(refresh.access_token)
            })
        except Exception as e:
            return Response(
                {'error': 'Invalid refresh token'},
                status=status.HTTP_401_UNAUTHORIZED
            )


class SessionBootstrapView(APIView):
    """Ensure a Django session + CSRF token exists for JWT-authenticated clients."""

    permission_classes = (IsAuthenticated,)
    authentication_classes = (JWTAuthentication,)

    def post(self, request):
        user = request.user

        # django_login expects the backend attribute when authenticating via JWT
        if not hasattr(user, 'backend'):
            user.backend = 'django.contrib.auth.backends.ModelBackend'

        django_login(request, user)

        session_key = request.session.session_key
        csrf_token = get_token(request)

        response = Response(
            {
                'message': 'Session ready',
                'sessionid': session_key,
                'csrftoken': csrf_token,
            },
            status=status.HTTP_200_OK,
        )

        # Provide cookies for browser clients, but Flutter can use JSON payload directly
        response.set_cookie('sessionid', session_key, httponly=True, samesite='Lax')
        response.set_cookie('csrftoken', csrf_token, samesite='Lax')
        return response
