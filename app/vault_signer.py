import os
import time
import threading
import base64
import hvac
from dotenv import load_dotenv

load_dotenv()

_KEY_NAME = "session-keys"

# Cache one authenticated Vault client and reuse it across encrypt/decrypt calls
# instead of doing a full AppRole login every time. AppRole tokens have a ~1h TTL,
# so a UserOp that decrypts twice (dummy-sign + real-sign) previously did 2 logins
# + 2 transit calls; now it does at most 1 login (only when the token is near
# expiry) + the transit calls. A lock serialises re-login so concurrent bot
# threads don't each mint a token, and any auth failure forces a one-shot re-login.
_client: hvac.Client | None = None
_token_expiry: float = 0.0
_lock = threading.Lock()
_EXPIRY_MARGIN_SECS = 60  # refresh this many seconds before the token actually expires


def _login() -> hvac.Client:
    client = hvac.Client(url=os.getenv("VAULT_ADDR"))
    auth = client.auth.approle.login(
        role_id=os.getenv("VAULT_ROLE_ID"),
        secret_id=os.getenv("VAULT_SECRET_ID"),
    )
    ttl = auth.get("auth", {}).get("lease_duration", 3600)
    global _token_expiry
    _token_expiry = time.time() + ttl - _EXPIRY_MARGIN_SECS
    return client


def _get_client() -> hvac.Client:
    global _client
    if _client is not None and time.time() < _token_expiry:
        return _client
    with _lock:
        # Re-check inside the lock: another thread may have just refreshed.
        if _client is None or time.time() >= _token_expiry:
            _client = _login()
        return _client


def _invalidate() -> None:
    global _client, _token_expiry
    with _lock:
        _client = None
        _token_expiry = 0.0


def _transit(op):
    """Runs a transit op with the cached client, re-logging in once if the token was
    rejected. Only Forbidden (Vault's response for an expired/revoked token) triggers a
    retry; data/config errors (bad ciphertext, missing key) surface immediately."""
    try:
        return op(_get_client())
    except hvac.exceptions.Forbidden:
        _invalidate()
        return op(_get_client())


def encrypt_key(raw_key: bytes) -> str:
    b64 = base64.b64encode(raw_key).decode()
    result = _transit(lambda c: c.secrets.transit.encrypt_data(name=_KEY_NAME, plaintext=b64))
    return result["data"]["ciphertext"]


def decrypt_key(ciphertext: str) -> bytes:
    result = _transit(lambda c: c.secrets.transit.decrypt_data(name=_KEY_NAME, ciphertext=ciphertext))
    return base64.b64decode(result["data"]["plaintext"])
