#!/usr/bin/env bash
# Get a wger DRF Token for eval use.
#
# wger uses Django REST Framework token auth (Authorization: Token <40-char-hex>).
# /api/v2/login/ was removed in wger 2.7+, so the token is retrieved via Django
# ORM inside the running web container.
#
# The wger entrypoint creates the admin user after gunicorn starts, so the API
# can respond to /api/v2/version/ before the admin user exists. We therefore
# retry the ORM call (up to 60s) until a valid 40-char hex token is returned,
# rather than trusting a single attempt after the HTTP readiness check.
#
# Outputs the bare 40-char token key to stdout (no trailing newline).
set -euo pipefail

WGER_HOST="${WGER_HOST:-http://localhost:8091}"
WGER_USER="${SKYRAMP_UI_USERNAME:-admin}"
DOCKER_PROJECT="${DOCKER_PROJECT:-eval-25-wger}"

echo "  [get-auth-token] wger: ${WGER_HOST}" >&2
echo "  [get-auth-token] user: ${WGER_USER}" >&2

# Wait for the wger HTTP API to respond (up to 120s).
for i in $(seq 1 40); do
  if curl -sf -m5 -o /dev/null "${WGER_HOST}/api/v2/version/"; then
    echo "  [get-auth-token] API ready after $((i*3))s" >&2
    break
  fi
  sleep 3
  [ "$i" = 40 ] && { echo "  [get-auth-token] ERROR: API not ready after 120s" >&2; exit 1; }
done

# Fetch the DRF token via Django ORM. The admin user is created by the wger
# entrypoint after gunicorn starts, so we retry until a valid token appears.
# Username is passed as argv[1] to avoid shell-interpolation issues.
TOKEN=""
for attempt in $(seq 1 20); do
  TOKEN=$(docker compose -p "${DOCKER_PROJECT}" exec -T web \
    python3 - "${WGER_USER}" <<'PYEOF'
import sys, os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'settings.main')
import django
django.setup()
from django.contrib.auth.models import User
from rest_framework.authtoken.models import Token
username = sys.argv[1]
try:
    user = User.objects.get(username=username)
    token, _ = Token.objects.get_or_create(user=user)
    sys.stdout.write(token.key)
except Exception as e:
    print(f"  [get-auth-token] ORM error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
  2>/dev/null | tr -d '\r\n') || true

  # DRF token keys are exactly 40 lowercase hex characters.
  if [[ "${TOKEN}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "  [get-auth-token] token obtained (attempt ${attempt})" >&2
    break
  fi

  echo "  [get-auth-token] attempt ${attempt}: invalid token '${TOKEN:0:20}...' — retrying in 3s" >&2
  TOKEN=""
  sleep 3
done

if [[ -z "${TOKEN}" ]]; then
  echo "  [get-auth-token] ERROR: failed to obtain a valid token after 20 attempts" >&2
  exit 1
fi

printf '%s' "${TOKEN}"
