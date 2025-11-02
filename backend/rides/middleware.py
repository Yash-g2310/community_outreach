from urllib.parse import parse_qs
from channels.db import database_sync_to_async
from rest_framework_simplejwt.tokens import AccessToken
from django.contrib.auth.models import AnonymousUser
from django.contrib.auth import get_user_model

User = get_user_model()


@database_sync_to_async
def get_user_from_token(token):
    """Extract user from JWT token"""
    try:
        access_token = AccessToken(token)
        user_id = access_token["user_id"]
        user = User.objects.get(id=user_id)
        return user
    except Exception as e:
        print(f"❌ JWT Middleware Error: {e}")
        return AnonymousUser()


class JWTAuthMiddleware:
    """Django Channels 4 compatible JWT middleware"""

    def __init__(self, inner):
        self.inner = inner

    async def __call__(self, scope, receive, send):
        query_string = scope.get("query_string", b"").decode()
        query_params = parse_qs(query_string)
        token_list = query_params.get("token")

        if token_list:
            token = token_list[0]
            user = await get_user_from_token(token)
            if user and user.is_authenticated:
                print(f"✅ WS Authenticated: {user.username}")
            else:
                print("⚠️ Invalid or expired JWT")
            scope["user"] = user
        else:
            print("⚠️ No JWT token provided in WS URL")
            scope["user"] = AnonymousUser()

        inner = self.inner
        return await inner(scope, receive, send)