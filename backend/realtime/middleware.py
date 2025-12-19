"""WebSocket authentication middleware for JWT and Cookie-based auth."""

import logging
from urllib.parse import parse_qs

from asgiref.sync import sync_to_async
from channels.middleware import BaseMiddleware
from django.contrib.auth import get_user_model
from django.contrib.auth.models import AnonymousUser
from rest_framework_simplejwt.tokens import AccessToken

User = get_user_model()
logger = logging.getLogger(__name__)


class JWTOrCookieAuthMiddleware(BaseMiddleware):
    """
    Authenticate WebSocket connections using either:
    1. JWT in querystring (?token=...)
    2. Session cookies (sessionid, csrftoken) - for browser use
    """

    async def __call__(self, scope, receive, send):
        query_string = scope.get("query_string", b"").decode()
        params = parse_qs(query_string)

        # 1) JWT from query params (MOBILE)
        token_list = params.get("token")
        if token_list:
            try:
                token = token_list[0]
                access = AccessToken(token)
                user_id = access["user_id"]

                user = await sync_to_async(User.objects.get)(id=user_id)
                scope["user"] = user
                return await super().__call__(scope, receive, send)

            except Exception as e:
                logger.debug("JWT auth failed: %s", e)
                scope["user"] = AnonymousUser()
                return await super().__call__(scope, receive, send)

        # 2) Cookie/session auth fallback (BROWSER)
        if "session" in scope:
            scope["user"] = scope.get("user", AnonymousUser())
            return await super().__call__(scope, receive, send)

        # Default: anonymous
        scope["user"] = AnonymousUser()
        return await super().__call__(scope, receive, send)
