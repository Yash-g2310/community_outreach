import urllib.parse

from channels.middleware import BaseMiddleware


class QueryStringCookieMiddleware(BaseMiddleware):
    """Inject session/csrf cookies from WebSocket query parameters."""

    async def __call__(self, scope, receive, send):
        query_string = scope.get("query_string", b"")
        if query_string:
            params = urllib.parse.parse_qs(query_string.decode())
            session_values = params.get("sessionid") or []
            csrf_values = params.get("csrftoken") or []
            session_id = session_values[0] if session_values else None
            csrf_token = csrf_values[0] if csrf_values else None

            if session_id:
                headers = dict(scope.get("headers", []))
                cookie_header = headers.get(b"cookie", b"")
                cookie_parts = []
                if cookie_header:
                    cookie_parts.append(cookie_header.decode())
                cookie_parts.append(f"sessionid={session_id}")
                if csrf_token:
                    cookie_parts.append(f"csrftoken={csrf_token}")
                headers[b"cookie"] = "; ".join(cookie_parts).encode()
                scope["headers"] = list(headers.items())

        return await super().__call__(scope, receive, send)
