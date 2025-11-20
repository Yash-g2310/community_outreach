"""
ASGI config for app_backend project.

It exposes the ASGI callable as a module-level variable named ``application``.

For more information on this file, see
https://docs.djangoproject.com/en/5.2/howto/deployment/asgi/
"""

import os
from django.core.asgi import get_asgi_application
from channels.routing import ProtocolTypeRouter, URLRouter
from channels.auth import AuthMiddlewareStack
from channels.security.websocket import AllowedHostsOriginValidator
from rides.middleware import QueryStringCookieMiddleware

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'app_backend.settings')

# Initialize Django ASGI application early to ensure the AppRegistry
# is populated before importing code that may import ORM models.
django_asgi_app = get_asgi_application()

# Import routing after Django setup
from rides.routing import websocket_urlpatterns

application = ProtocolTypeRouter({
    "http": django_asgi_app,
    "websocket": AllowedHostsOriginValidator(
        QueryStringCookieMiddleware(
            AuthMiddlewareStack(
                URLRouter(websocket_urlpatterns)
            )
        )
    ),
})
