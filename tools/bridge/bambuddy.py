"""Minimal Bambuddy REST client for the bridge (internal inventory mode).

Routes verified against maziggy/bambuddy 1.2.5.2; see the plan's Context
section. Every request carries `X-API-Key`.
"""

import string

import httpx

API = "/api/v1"
TIMEOUT = 5.0


class BambuddyError(Exception):
    """A Bambuddy call failed: network error or unexpected status."""


class SpoolNotFound(BambuddyError):
    """Bambuddy answered 404 for the spool."""

    def __init__(self, spool_id: int):
        super().__init__(f"spool {spool_id} not found")
        self.spool_id = spool_id


class PermissionMissing(BambuddyError):
    def __init__(self, permission: str):
        super().__init__(f"API key lacks the {permission} permission")
        self.permission = permission


def net_to_gross(net: int, core: int | None) -> int:
    """Gross scale weight for `net` grams of filament on a `core` gram spool."""
    return net + (core or 0)


def used_after_weighing(spool: dict, gross: int) -> float:
    """`weight_used` after a `gross` scale weight, as Bambuddy computes it."""
    net = max(0, gross - (spool.get("core_weight") or 0))
    return max(0, spool.get("label_weight", 0) - net)


def is_archived(spool: dict) -> bool:
    """Whether the spool is in Bambuddy's archive: an explicit `archived`
    flag wins over `archived_at`."""
    archived = spool.get("archived")
    if archived is not None:
        return bool(archived)
    return spool.get("archived_at") is not None


def remaining(spool: dict) -> int:
    """Filament left on a spool, in grams, never negative."""
    left = spool.get("label_weight", 0) - (spool.get("weight_used") or 0)
    return max(0, round(left))


def color_name(color_map: dict | None, rgba: str | None, detailed_type: str | None) -> str | None:
    """Bambuddy's name for a colour, as an AMS-added spool gets it.

    `color_map` is what `BambuddyClient.color_map` returns. The material table
    (`"<detailed type>|<hex>"`) comes first, then the colour table; `None` when
    neither knows the colour. The alpha byte never matters.
    """
    if not color_map or not rgba:
        return None
    value = rgba.removeprefix("#")
    if len(value) not in (6, 8) or not all(c in string.hexdigits for c in value):
        return None
    hex6 = value[:6].lower()
    if detailed_type:
        name = color_map.get("by_material", {}).get(f"{detailed_type.lower()}|{hex6}")
        if name:
            return name
    return color_map.get("colors", {}).get(hex6)


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
            try:
                return response.json()
            except ValueError as error:
                raise BambuddyError(
                    f"{response.request.method} {response.request.url.path}: "
                    f"reply is not JSON: {response.text[:120]}"
                ) from error
        raise BambuddyError(
            f"{response.request.method} {response.request.url.path}: "
            f"HTTP {response.status_code} {response.text[:120]}"
        )

    def find_by_tag(self, tray_uuid: str | None, tag_uid: str) -> dict | None:
        """The spool carrying this tag: the tray UUID when there is one, then
        the UID. Archived spools count, so a spool marked empty is found again
        rather than added twice."""
        queries = ([{"tray_uuid": tray_uuid}] if tray_uuid else []) + [{"tag_uid": tag_uid}]
        for params in queries:
            params = {**params, "include_archived": "true"}
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

    def _spool_write(self, method: str, path: str, spool_id: int, **kwargs) -> httpx.Response:
        response = self._request(method, path, **kwargs)
        if response.status_code == 404:
            raise SpoolNotFound(spool_id)
        if not response.is_success:
            self._json(response)  # raises with the status
        return response

    def set_weight_used(self, spool_id: int, grams: int) -> dict:
        """`PATCH /inventory/spools/{id}`: 0 marks the spool full, the label
        weight marks it empty."""
        path = f"/inventory/spools/{spool_id}"
        return self._json(self._spool_write("PATCH", path, spool_id, json={"weight_used": grams}))

    def archive_spool(self, spool_id: int) -> None:
        """Move the spool to the archive; the reply's body is not read."""
        self._spool_write("POST", f"/inventory/spools/{spool_id}/archive", spool_id)

    def restore_spool(self, spool_id: int) -> None:
        """Bring an archived spool back; the reply's body is not read."""
        self._spool_write("POST", f"/inventory/spools/{spool_id}/restore", spool_id)

    def delete_spool(self, spool_id: int) -> None:
        self._spool_write("DELETE", f"/inventory/spools/{spool_id}", spool_id)

    def create_spool(self, body: dict) -> dict:
        if not body.get("material"):
            raise ValueError("refusing to create a spool without material")
        return self._json(self._request("POST", "/inventory/spools", json=body))

    def color_map(self) -> dict:
        """`GET /inventory/colors/map`: `colors` by hex and `by_material` by
        `"<material>|<hex>"`, keys lower-cased."""
        response = self._request("GET", "/inventory/colors/map")
        if response.status_code == 403:
            raise PermissionMissing("inventory:read")
        reply = self._json(response)
        tables = {}
        for table in ("colors", "by_material"):
            entries = (reply.get(table) or {}) if isinstance(reply, dict) else None
            if not isinstance(entries, dict) or not all(
                isinstance(key, str) and isinstance(name, str) for key, name in entries.items()
            ):
                raise BambuddyError(f"GET /inventory/colors/map: not a colour map: {str(reply)[:120]}")
            tables[table] = {key.lower(): name for key, name in entries.items()}
        return tables

    def spoolman_enabled(self) -> bool:
        response = self._request("GET", "/settings/spoolman")
        if response.status_code == 403:
            raise PermissionMissing("settings:read")
        value = self._json(response).get("spoolman_enabled")
        return value is True or str(value).lower() == "true"
