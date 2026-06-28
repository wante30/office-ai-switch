import hmac
from typing import Iterable

from fastapi.responses import JSONResponse


class GatewayAccessMiddleware:
    """Require a separate client token on public inference endpoints."""

    def __init__(self, app, token: str, protected_paths: Iterable[str]):
        self.app = app
        self.token = token.strip()
        self.protected_paths = frozenset(protected_paths)

    async def __call__(self, scope, receive, send):
        if (
            self.token
            and scope.get("type") == "http"
            and scope.get("method") != "OPTIONS"
            and scope.get("path") in self.protected_paths
        ):
            headers = {
                key.decode("latin-1").lower(): value.decode("latin-1")
                for key, value in scope.get("headers", [])
            }
            presented = headers.get("x-api-key", "").strip()
            authorization = headers.get("authorization", "").strip()
            if authorization.lower().startswith("bearer "):
                presented = authorization[7:].strip()

            if not presented or not hmac.compare_digest(presented, self.token):
                response = JSONResponse(status_code=401, content={"detail": "Invalid gateway token"})
                await response(scope, receive, send)
                return

        await self.app(scope, receive, send)
