#!/usr/bin/env bash
# PRZMA authorisation scope — end-to-end test on the server.
#
# Flow: Keycloak login -> completeRegistration (central rows + storage) -> myAccess
#       -> chat -> calendar event with meeting link -> invite -> scope checks
#       -> access key (X-API-Key) -> sessions -> admin (optional).
#
# Users (Keycloak password Test@1234 unless PASSWORD is set):
#   T1_USER     a tier1-user  (free plan, shared bucket perkeep)     default kc_user4
#   T2_USER     a tier2-user  (premium plan, own bucket przma-<uuid>) default kc_user5
#   ADMIN_USER  a user you made platform_admin with SQL (see guide)    default kc_user3
# Usage:
#   bash scripts/authz_curl_test.sh
#   ADMIN_TESTS=1 bash scripts/authz_curl_test.sh   # also plan change + suspend (changes data)
BASE="${BASE:-http://localhost:4200}"
API="$BASE/api/graphql"
KC="${KC:-http://172.235.18.126:8180/realms/przma/protocol/openid-connect/token}"
PASSWORD="${PASSWORD:-Test@1234}"
T1_USER="${T1_USER:-kc_user4}"
T2_USER="${T2_USER:-kc_user5}"
ADMIN_USER="${ADMIN_USER:-kc_user3}"
PASS=0; FAIL=0

command -v jq >/dev/null || { echo "jq is missing: apt-get install -y jq"; exit 1; }

gql() {
  local vars="${3:-}"; [ -z "$vars" ] && vars='{}'
  curl -s "$API" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg q "$2" --argjson v "$vars" '{query:$q, variables:$v}')"
}
gql_key() {
  local vars="${3:-}"; [ -z "$vars" ] && vars='{}'
  curl -s "$API" -H "X-API-Key: $1" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg q "$2" --argjson v "$vars" '{query:$q, variables:$v}')"
}
vars() { local a=(); for kv in "$@"; do a+=(--arg "${kv%%=*}" "${kv#*=}"); done; jq -cn "${a[@]}" '$ARGS.named'; }
tok() {
  curl -s -X POST "$KC" -d client_id=przma-app -d client_secret=przma-secret-2024 \
    -d grant_type=password -d "username=$1" -d "password=$PASSWORD" | jq -r .access_token
}
# rest METHOD PATH HEADER -> sets $CODE and $BODY
rest() {
  local out
  out=$(curl -s -w $'\n%{http_code}' -X "$1" "$BASE$2" -H "$3")
  CODE="${out##*$'\n'}"; BODY="${out%$'\n'*}"
}
check() {
  if echo "$2" | jq -e "${@:4}" "$3" >/dev/null 2>&1; then
    echo "[PASS] $1"; PASS=$((PASS + 1))
  else
    echo "[FAIL] $1"; echo "       got: $(echo "$2" | head -c 700)"; FAIL=$((FAIL + 1))
  fi
}
check_code() {
  if [ "$2" = "$3" ]; then echo "[PASS] $1"; PASS=$((PASS + 1)); else echo "[FAIL] $1 (HTTP $2, expected $3)"; echo "       got: $(echo "$4" | head -c 400)"; FAIL=$((FAIL + 1)); fi
}
section() { echo; echo "=== $1 ==="; }

section "0. Keycloak tokens and server"
T1=$(tok "$T1_USER"); T2=$(tok "$T2_USER"); TA=$(tok "$ADMIN_USER")
for pair in "$T1_USER:$T1" "$T2_USER:$T2"; do
  u="${pair%%:*}"; t="${pair#*:}"
  if [ -n "$t" ] && [ "$t" != "null" ]; then echo "[PASS] token $u"; PASS=$((PASS+1)); else echo "[FAIL] token $u (does the user exist in Keycloak?)"; exit 1; fi
done
R=$(gql "$T1" '{ __type(name: "AccessProfile") { name } }')
check "server runs the authorisation-scope code" "$R" '.data.__type.name == "AccessProfile"'
echo "$R" | jq -e '.data.__type.name == "AccessProfile"' >/dev/null 2>&1 || { echo "Restart the server with the new code first."; exit 1; }
U1="did:przma:$T1_USER"; U2="did:przma:$T2_USER"

section "1. Registration creates the central rows"
R=$(gql "$T1" '{ myAccess { plan } }')
echo "  before registration: $(echo "$R" | jq -c '.errors[0].message // .data.myAccess')"
R=$(gql "$T1" 'mutation { completeRegistration { status did plan storagePath } }')
check "$T1_USER registered (plan free)" "$R" '.data.completeRegistration.status == "registered" and .data.completeRegistration.plan == "free"'
R=$(gql "$T2" 'mutation { completeRegistration { status did plan storagePath } }')
check "$T2_USER registered (plan premium)" "$R" '.data.completeRegistration.status == "registered" and .data.completeRegistration.plan == "premium"'
echo "  $T2_USER storage path: $(echo "$R" | jq -r .data.completeRegistration.storagePath)"
[ -n "$TA" ] && [ "$TA" != "null" ] && gql "$TA" 'mutation { completeRegistration { status } }' >/dev/null

section "2. myAccess: role, scopes, storage tier"
R=$(gql "$T1" '{ myAccess { did status plan roles scopes features storage { tier bucket basePath status } quotaBytes usedBytes sessionPolicy { maxSessionSeconds maxDevices maxKeyDays } } }')
check "$T1_USER: basic_user, tier 1, bucket perkeep" "$R" '.data.myAccess.roles == ["basic_user"] and .data.myAccess.storage.tier == 1 and .data.myAccess.storage.bucket == "perkeep"'
check "$T1_USER: no keys:manage scope" "$R" '(.data.myAccess.scopes | index("keys:manage")) == null'
R=$(gql "$T2" '{ myAccess { plan roles storage { tier bucket basePath status } quotaBytes } }')
check "$T2_USER: privileged_user, tier 2, storage ready" "$R" '.data.myAccess.roles == ["privileged_user"] and .data.myAccess.storage.tier == 2 and .data.myAccess.storage.status == "ready"'
B2=$(echo "$R" | jq -r .data.myAccess.storage.bucket)
if [[ "$B2" == przma-* ]]; then echo "[PASS] $T2_USER has own bucket $B2"; PASS=$((PASS+1));
else echo "[INFO] $T2_USER stays on '$B2' (had data there before) — move with adminMigrateStorage"; fi

section "3. Chat: $T1_USER -> $T2_USER"
R=$(gql "$T1" 'mutation($to: String!) { sendMessage(toDid: $to, content: "Can we meet tomorrow?") { id } }' "$(vars to="$U2")")
check "sendMessage allowed (social:rw)" "$R" '.data.sendMessage.id != null'
R=$(gql "$T2" '{ threads { threadKey } }')
check "$T2_USER sees the thread" "$R" '(.data.threads | length) >= 1'

section "4. Calendar: schedule a meeting and invite"
R=$(gql "$T1" '{ myCalendars { calendarId isDefault } }')
CAL=$(echo "$R" | jq -r '[.data.myCalendars[] | select(.isDefault)][0].calendarId // .data.myCalendars[0].calendarId')
check "myCalendars allowed (calendar:read)" "$R" '(.data.myCalendars | length) >= 1'
START=$(date -d "tomorrow 11:00" +%Y-%m-%dT%H:%M:00+05:30); END=$(date -d "tomorrow 11:30" +%Y-%m-%dT%H:%M:00+05:30)
R=$(gql "$T1" 'mutation($c: String!, $s: String!, $e: String!) { createEvent(calendarId: $c, input: {title: "Project sync", startsAt: $s, endsAt: $e, location: "https://meet.jit.si/przma-project-sync", reminders: [10]}) { eventId title location } }' "$(vars c="$CAL" s="$START" e="$END")")
check "createEvent with meeting link (calendar:rw)" "$R" '.data.createEvent.eventId != null'
EV=$(echo "$R" | jq -r .data.createEvent.eventId)
R=$(gql "$T1" 'mutation($c: String!, $e: String!, $u: String!) { inviteToEvent(calendarId: $c, eventId: $e, userDids: [$u]) { inviteeDid rsvp } }' "$(vars c="$CAL" e="$EV" u="$U2")")
check "inviteToEvent $T2_USER" "$R" '.data.inviteToEvent[0].inviteeDid != null'
R=$(gql "$T2" 'mutation($c: String!, $e: String!) { rsvpEvent(calendarId: $c, eventId: $e, response: "accepted") }' "$(vars c="$CAL" e="$EV")")
check "$T2_USER accepts" "$R" '.data.rsvpEvent == true'
R=$(gql "$T1" 'mutation($to: String!, $m: String!) { sendMessage(toDid: $to, content: $m) { id } }' "$(vars to="$U2" m="Project sync tomorrow 11:00 https://meet.jit.si/przma-project-sync")")
check "share the meeting link by chat" "$R" '.data.sendMessage.id != null'

section "5. Scope and plan checks"
R=$(gql "$T1" 'mutation { createAccessKey(name: "test", scopes: ["calendar:read"], days: 5) { key } }')
check "$T1_USER (basic) createAccessKey -> scope_denied" "$R" '.errors[0].message == "scope_denied" and .errors[0].extensions.needed == "keys:manage"'
R=$(gql "$T1" '{ adminSecurityEvents(limit: 1) { eventType } }')
check "$T1_USER adminSecurityEvents -> scope_denied" "$R" '.errors[0].message == "scope_denied"'

section "6. Access key (X-API-Key) for $T2_USER"
R=$(gql "$T2" 'mutation { createAccessKey(name: "My CRM", scopes: ["calendar:read"], days: 30) { key accessKey { id keyPrefix expiresAt } } }')
check "$T2_USER (premium) createAccessKey" "$R" '.data.createAccessKey.key | startswith("pk_live_")'
KEY=$(echo "$R" | jq -r .data.createAccessKey.key); KEYID=$(echo "$R" | jq -r .data.createAccessKey.accessKey.id)
R=$(gql "$T2" 'mutation { createAccessKey(name: "too long", scopes: ["calendar:read"], days: 365) { key } }')
check "key longer than 90 days refused" "$R" '.errors[0].message | test("days must be")'
R=$(gql_key "$KEY" '{ myCalendars { calendarId } }')
check "key: myCalendars (calendar:read) -> ok" "$R" '(.data.myCalendars | length) >= 1'
R=$(gql_key "$KEY" 'mutation { createCalendar(name: "x") { calendarId } }')
check "key: createCalendar needs calendar:rw -> scope_denied" "$R" '.errors[0].message == "scope_denied"'
rest GET /api/v1/profile "X-API-Key: $KEY"
check_code "REST GET /api/v1/profile with read-only key -> 403" "$CODE" 403 "$BODY"
rest GET /api/v1/profile "X-API-Key: pk_live_wrong"
check_code "wrong key -> 401" "$CODE" 401 "$BODY"
rest GET /api/v1/profile "Authorization: Bearer $T2"
check_code "REST GET /api/v1/profile with JWT -> 200" "$CODE" 200 "$BODY"
R=$(gql "$T2" 'mutation($id: String!) { revokeAccessKey(id: $id) }' "$(vars id="$KEYID")")
check "revokeAccessKey" "$R" '.data.revokeAccessKey == true'
rest GET /api/v1/search/stats "X-API-Key: $KEY"
check_code "revoked key -> 401" "$CODE" 401 "$BODY"

section "7. Sessions"
R=$(gql "$T1" '{ mySessions { sid device current lastSeenAt } }')
check "mySessions shows the current login" "$R" '[.data.mySessions[] | select(.current)] | length == 1'

section "8. Admin ($ADMIN_USER)"
R=$(gql "$TA" '{ adminSecurityEvents(limit: 5) { eventType severity did actionTaken createdAt } }')
if echo "$R" | jq -e '.data.adminSecurityEvents' >/dev/null 2>&1; then
  check "adminSecurityEvents (latest 5)" "$R" '(.data.adminSecurityEvents | length) >= 1'
  echo "$R" | jq -r '.data.adminSecurityEvents[] | "  \(.createdAt)  \(.eventType)  \(.did)  \(.actionTaken)"'
  R=$(gql "$TA" 'query($d: String!) { adminAccount(did: $d) { plan roles usedBytes quotaBytes storage { bucket } } }' "$(vars d="$U1")")
  check "adminAccount $T1_USER" "$R" '.data.adminAccount.plan != null'
  if [ "${ADMIN_TESTS:-0}" = "1" ]; then
    R=$(gql "$TA" 'mutation($d: String!) { adminSetAccountStatus(did: $d, status: "suspended", reason: "test") { status } }' "$(vars d="$U1")")
    check "suspend $T1_USER" "$R" '.data.adminSetAccountStatus.status == "suspended"'
    R=$(gql "$T1" '{ myCalendars { calendarId } }')
    check "suspended user -> account_suspended" "$R" '.errors[0].message == "account_suspended"'
    gql "$TA" 'mutation($d: String!) { adminSetAccountStatus(did: $d, status: "active") { status } }' "$(vars d="$U1")" >/dev/null
    T1=$(tok "$T1_USER")
    R=$(gql "$T1" '{ myCalendars { calendarId } }')
    check "reactivated + new login -> ok" "$R" '(.data.myCalendars | length) >= 1'
    R=$(gql "$TA" 'mutation($d: String!) { adminSetPlan(did: $d, plan: "premium") { plan role storage } }' "$(vars d="$U1")")
    check "adminSetPlan $T1_USER -> premium (storage copy starts)" "$R" '.data.adminSetPlan.plan == "premium"'
    sleep 3
    R=$(gql "$T1" 'mutation { createAccessKey(name: "after upgrade", scopes: ["calendar:read"], days: 5) { key } }')
    check "$T1_USER can create keys after upgrade" "$R" '.data.createAccessKey.key | startswith("pk_live_")'
  else
    echo "  (set ADMIN_TESTS=1 to also test suspend and plan change)"
  fi
else
  echo "[INFO] $ADMIN_USER is not platform_admin (see the guide, step 'Make an admin'): $(echo "$R" | jq -c '.errors[0].message')"
fi

echo; echo "=== RESULT: $PASS passed, $FAIL failed ==="
