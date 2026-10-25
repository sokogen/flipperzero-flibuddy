"""Minimal Bambuddy REST client for the bridge (internal inventory mode).

Routes verified against maziggy/bambuddy 1.2.5.2; see the plan's Context
section. Every request carries `X-API-Key`.
"""

import httpx

API = "/api/v1"
TIMEOUT = 5.0


class BambuddyError(Exception):
    """A Bambuddy call failed: network error or unexpected status."""


class PermissionMissing(BambuddyError):
    def __init__(self, permission: str):
        super().__init__(f"API key lacks the {permission} permission")
        self.permission = permission


def net_to_gross(net: int, core: int | None) -> int:
    """Gross scale weight for `net` grams of filament on a `core` gram spool."""
    return net + (core or 0)


def remaining(spool: dict) -> int:
    """Filament left on a spool, in grams, never negative."""
    left = spool.get("label_weight", 0) - (spool.get("weight_used") or 0)
    return max(0, round(left))


class BambuddyClient:
    def __init__(self, base_url: str, api_key: str, transport: httpx.BaseTransport | None = None):
        self._http = httpx.Client(
            base_url=base_url.rstrip("/") + API,
            headers={"X-API-Key": api_key},
            timeout=TIMEOUT,
            transport=transport,
        )

    def _request(self, method: str, path: str, **kwargs) -> httpx.Response:
        try:
            return self._http.request(method, path, **kwargs)
        except httpx.HTTPError as error:
            raise BambuddyError(f"{method} {path}: {error}") from error

    def _json(self, response: httpx.Response):
        if response.is_success:
            return response.json()
        raise BambuddyError(
            f"{response.request.method} {response.request.url.path}: "
            f"HTTP {response.status_code} {response.text[:120]}"
        )

    def find_by_tag(self, tray_uuid_candidates: list[str], tag_uid: str) -> dict | None:
        """The spool carrying this tag: tray UUID candidates in order, then the UID."""
        queries = [{"tray_uuid": c} for c in tray_uuid_candidates] + [{"tag_uid": tag_uid}]
        for params in queries:
            response = self._request("GET", "/inventory/spools/by-tag", params=params)
            if response.status_code != 404:
                return self._json(response)
        return None

    def get_spool(self, spool_id: int) -> dict:
        return self._json(self._request("GET", f"/inventory/spools/{spool_id}"))

    def update_weight(self, spool_id: int, gross: int) -> dict:
        """Record a gross scale weight; Bambuddy subtracts the core weight."""
        body = {"spool_id": spool_id, "weight_grams": gross}
        return self._json(self._request("POST", "/spoolbuddy/scale/update-spool-weight", json=body))

    def create_spool(self, body: dict) -> dict:
        if not body.get("material"):
            raise ValueError("refusing to create a spool without material")
        return self._json(self._request("POST", "/inventory/spools", json=body))

    def spoolman_enabled(self) -> bool:
        response = self._request("GET", "/settings/spoolman")
        if response.status_code == 403:
            raise PermissionMissing("settings:read")
        value = self._json(response).get("spoolman_enabled")
        return value is True or str(value).lower() == "true"
