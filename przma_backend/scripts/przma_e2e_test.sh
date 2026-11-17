#!/usr/bin/env bash
# PRZMA full end-to-end test — 5 users, authorisation scope included
# Usage: BASE=http://localhost:4000 USERS="u1 u2 u3 u4 u5" ADMIN_USER=kc_user3 bash scripts/przma_e2e_test.sh
#        add ADMIN_TESTS=1 for upgrade / downgrade / suspend tests
BASE="${BASE:-http://localhost:4200}"
API="$BASE/api/graphql"
KC="${KC:-http://przma-dev-keycloak:8080/realms/przma/protocol/openid-connect/token}"
PASSWORD="${PASSWORD:-Test@1234}"
read -r -a USERS <<< "${USERS:-kc_user2 kc_user3 kc_user4 kc_user5 kc_user6}"
ADMIN_USER="${ADMIN_USER:-kc_user3}"
PASS=0; FAIL=0; INFO=0
TMPD=$(mktemp -d)

command -v jq >/dev/null || { echo "jq is missing: apt-get install -y jq"; exit 1; }

tok() {
  curl -s -X POST "$KC" -d client_id="$KC_CLIENT_ID" -d client_secret="$KC_CLIENT_SECRET" \
    -d grant_type=password -d "username=$1" -d "password=$PASSWORD" | jq -r '.access_token // empty'
}
v() { local a=(); for kv in "$@"; do a+=(--arg "${kv%%=*}" "${kv#*=}"); done; jq -cn "${a[@]}" '$ARGS.named'; }
gql() {
  local vars="${3:-}"; [ -z "$vars" ] && vars='{}'
  curl -s "$API" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg q "$2" --argjson v "$vars" '{query:$q, variables:$v}')"
}
gqlk() {
  local vars="${3:-}"; [ -z "$vars" ] && vars='{}'
  curl -s "$API" -H "X-API-Key: $1" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg q "$2" --argjson v "$vars" '{query:$q, variables:$v}')"
}
http() {
  local out
  if [ -n "${3:-}" ]; then out=$(curl -s -w $'\n%{http_code}' -X "$1" "$BASE$2" -H "$3")
  else out=$(curl -s -w $'\n%{http_code}' -X "$1" "$BASE$2"); fi
  CODE="${out##*$'\n'}"; BODY="${out%$'\n'*}"
}
ok()   { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "[FAIL] $1"; [ -n "${2:-}" ] && echo "       got: $(echo "$2" | head -c 600)"; FAIL=$((FAIL + 1)); }
info() { echo "[INFO] $1"; INFO=$((INFO + 1)); }
check() { if echo "$2" | jq -e "${@:4}" "$3" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$2"; fi; }
check_code() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (HTTP $2, expected $3)" "$4"; fi; }
section() { echo; echo "================ $1 ================"; }
did() { echo "did:przma:$1"; }
tk() { echo "${TOKEN[$1]}"; }

section "0. Keycloak tokens and server"
declare -a NAME TOKEN
for u in "${USERS[@]}"; do
  t=$(tok "$u")
  if [ -n "$t" ]; then NAME+=("$u"); TOKEN+=("$t"); ok "token $u"
  else info "no token for $u (not in Keycloak or wrong password) — skipped"; fi
done
N=${#NAME[@]}
[ "$N" -ge 3 ] || { echo "Need at least 3 working users (have $N). Set USERS=\"u1 u2 u3 u4 u5\"."; exit 1; }
TA=$(tok "$ADMIN_USER")
echo "Users in this run: ${NAME[*]}   admin: $ADMIN_USER"
R=$(gql "$(tk 0)" '{ __type(name: "AccessProfile") { name } }')
check "server runs the authorisation-scope code" "$R" '.data.__type.name == "AccessProfile"'
echo "$R" | jq -e '.data.__type.name == "AccessProfile"' >/dev/null 2>&1 || { echo "Start the server with the new code first."; exit 1; }
http POST /api/graphql
check_code "GraphQL without a token -> 401" "$CODE" 401 "$BODY"
http GET /api/v1/profile "Authorization: Bearer not-a-real-token"
check_code "REST with a fake token -> 401" "$CODE" 401 "$BODY"
http GET /api/v1/profile "X-API-Key: pk_live_doesnotexist"
check_code "REST with an unknown access key -> 401" "$CODE" 401 "$BODY"
R=$(gql "$(tk 0)" '{ __schema { queryType { name } } }')
check "introspection open for GraphiQL docs" "$R" '.data.__schema.queryType.name != null'

section "1. Registration (central rows + storage tier)"
for i in $(seq 0 $((N-1))); do
  u=${NAME[$i]}; t=$(tk $i)
  R=$(gql "$t" '{ myAccess { plan } }')
  if echo "$R" | jq -e '.errors[0].message == "account_not_registered"' >/dev/null 2>&1; then
    ok "$u before registration -> account_not_registered"
  fi
  R=$(gql "$t" 'mutation { completeRegistration { status did plan storagePath } }')
  check "$u registered (plan $(echo "$R" | jq -r .data.completeRegistration.plan), $(echo "$R" | jq -r .data.completeRegistration.storagePath))" "$R" '.data.completeRegistration.status == "registered"'
done
R=$(gql "$(tk 0)" 'mutation { completeRegistration { status } }')
check "registration is safe to repeat" "$R" '.data.completeRegistration.status == "registered"'
[ -n "$TA" ] && gql "$TA" 'mutation { completeRegistration { status } }' >/dev/null

section "2. Who is basic / privileged (myAccess)"
declare -a ROLE PLAN TIER
BASIC=(); PRIV=()
printf "  %-10s %-9s %-16s %-4s %-46s %-8s %s\n" USER PLAN ROLE TIER BUCKET QUOTA_GB SESSION_DAYS
for i in $(seq 0 $((N-1))); do
  R=$(gql "$(tk $i)" '{ myAccess { plan roles scopes storage { tier bucket status } quotaBytes usedBytes sessionPolicy { maxSessionSeconds maxDevices maxKeyDays } } }')
  if ! echo "$R" | jq -e '.data.myAccess.plan' >/dev/null 2>&1; then bad "myAccess ${NAME[$i]}" "$R"; continue; fi
  PLAN[$i]=$(echo "$R" | jq -r .data.myAccess.plan)
  TIER[$i]=$(echo "$R" | jq -r .data.myAccess.storage.tier)
  roles=$(echo "$R" | jq -r '.data.myAccess.roles | join(",")')
  if echo "$roles" | grep -q "privileged_user\|business_user"; then ROLE[$i]=privileged; PRIV+=($i); else ROLE[$i]=basic; BASIC+=($i); fi
  printf "  %-10s %-9s %-16s %-4s %-46s %-8s %s\n" "${NAME[$i]}" "${PLAN[$i]}" "$roles" "${TIER[$i]}" \
    "$(echo "$R" | jq -r .data.myAccess.storage.bucket)" "$(( $(echo "$R" | jq -r .data.myAccess.quotaBytes) / 1073741824 ))" \
    "$(( $(echo "$R" | jq -r .data.myAccess.sessionPolicy.maxSessionSeconds) / 86400 ))"
  if [ "${ROLE[$i]}" = basic ]; then
    check "${NAME[$i]} basic: no keys:manage, no calendar:plus" "$R" '(.data.myAccess.scopes | index("keys:manage")) == null and (.data.myAccess.scopes | index("calendar:plus")) == null'
  else
    check "${NAME[$i]} privileged: keys:manage + calendar:plus, tier 2" "$R" '(.data.myAccess.scopes | index("keys:manage")) != null and (.data.myAccess.scopes | index("calendar:plus")) != null and .data.myAccess.storage.tier == 2'
    b=$(echo "$R" | jq -r .data.myAccess.storage.bucket)
    [[ "$b" == przma-* ]] && ok "${NAME[$i]} has its own bucket $b" || info "${NAME[$i]} is tier2 but stays on '$b' (had data there before; move with adminMigrateStorage)"
  fi
done
echo "  basic users: ${#BASIC[@]}   privileged users: ${#PRIV[@]}"
[ ${#BASIC[@]} -ge 1 ] || info "no basic (tier1) user in this run — basic-only checks are skipped"
[ ${#PRIV[@]} -ge 1 ] || info "no privileged (tier2) user in this run — privileged-only checks are skipped"
O=${BASIC[0]:-0}
OTHERS=(); for i in $(seq 0 $((N-1))); do [ "$i" != "$O" ] && OTHERS+=($i); done
X=${OTHERS[-1]}; MEM=("${OTHERS[@]:0:${#OTHERS[@]}-1}")
TO=$(tk $O); UO=$(did ${NAME[$O]}); TX=$(tk $X); UX=$(did ${NAME[$X]})
M1=${MEM[0]}; TM1=$(tk $M1); UM1=$(did ${NAME[$M1]})
echo "  organiser: ${NAME[$O]} (${ROLE[$O]})   group members: $(for m in "${MEM[@]}"; do echo -n "${NAME[$m]} "; done)  outside the group: ${NAME[$X]}"

section "3. Profile, contacts, follow"
R=$(gql "$TO" 'mutation { updateProfile(displayName: "Organiser Test") { did displayName } }')
check "updateProfile" "$R" '.data.updateProfile.displayName == "Organiser Test"'
R=$(gql "$TO" '{ profile { did displayName } }')
check "profile query" "$R" '.data.profile.did != null'
http GET /api/v1/profile "Authorization: Bearer $TO"
check_code "REST GET /api/v1/profile with JWT -> 200" "$CODE" 200 "$BODY"
for i in "${OTHERS[@]}"; do
  R=$(gql "$TO" 'mutation($d: String!) { addContact(did: $d) { contactDid } }' "$(v d=$(did ${NAME[$i]}))")
  check "${NAME[$O]} adds contact ${NAME[$i]}" "$R" '.data.addContact.contactDid != null or (.errors[0].message | test("already"))'
done
R=$(gql "$TO" '{ contacts { contactDid } }')
check "contacts list has $((N-1)) people" "$R" "(.data.contacts | length) >= $((N-1))"
R=$(gql "$TM1" 'mutation($d: String!) { followUser(did: $d) { __typename } }' "$(v d=$UO)")
check "${NAME[$M1]} follows ${NAME[$O]}" "$R" '.data.followUser != null or (.errors[0].message | test("already"))'

section "4. Chat: direct messages"
R=$(gql "$TO" 'mutation($to: String!) { sendMessage(toDid: $to, content: "Hi, can we meet tomorrow?") { id threadKey } }' "$(v to=$UM1)")
check "${NAME[$O]} -> ${NAME[$M1]}: sendMessage" "$R" '.data.sendMessage.id != null'
sleep 1
R=$(gql "$TM1" '{ unreadCount }')
check "${NAME[$M1]} has unread messages" "$R" '.data.unreadCount >= 1'
R=$(gql "$TM1" 'query($d: String!) { conversation(withDid: $d, limit: 5) { id threadKey content direction } }' "$(v d=$UO)")
check "${NAME[$M1]} reads the conversation" "$R" '[.data.conversation[] | select(.content == "Hi, can we meet tomorrow?")] | length >= 1'
TK1=$(echo "$R" | jq -r '.data.conversation[0].threadKey')
R=$(gql "$TM1" 'mutation($k: String!) { markThreadRead(threadKey: $k) { threadKey unreadCount } }' "$(v k=$TK1)")
check "markThreadRead" "$R" '.data.markThreadRead != null'
R=$(gql "$TM1" 'mutation($to: String!) { sendMessage(toDid: $to, content: "Yes, 11 AM works") { id } }' "$(v to=$UO)")
check "${NAME[$M1]} replies" "$R" '.data.sendMessage.id != null'
R=$(gql "$TO" '{ threads { threadKey peerDid } }')
check "${NAME[$O]} sees the thread" "$R" "[.data.threads[] | select(.peerDid == \"$UM1\")] | length >= 1"

section "5. Files: upload, list, download, quota, file in chat"
F="$TMPD/meeting-notes-$RANDOM.txt"; echo "PRZMA e2e test file $(date) $RANDOM$RANDOM" > "$F"
USED0=$(gql "$TO" '{ myAccess { usedBytes } }' | jq -r '.data.myAccess.usedBytes // 0')
R=$(curl -s "$API" -H "Authorization: Bearer $TO" \
  -F 'query=mutation { uploadFile(file: "f1", space: "private") { fileId contentCas refCount space } }' -F "f1=@$F;type=text/plain")
check "uploadFile (private)" "$R" '.data.uploadFile.contentCas != null'
CAS=$(echo "$R" | jq -r '.data.uploadFile.contentCas')
R=$(gql "$TO" '{ files(space: "private") { name sizeBytes contentCas } }')
check "file appears in files list" "$R" "[.data.files[] | select(.contentCas == \"$CAS\")] | length == 1"
R=$(gql "$TO" 'query($h: String!) { blobDownloadUrl(hash: $h, space: "private") { url expiresIn } }' "$(v h=$CAS)")
check "blobDownloadUrl for the owner" "$R" '.data.blobDownloadUrl.url | startswith("http")'
USED1=$(gql "$TO" '{ myAccess { usedBytes } }' | jq -r '.data.myAccess.usedBytes // 0')
[ "$USED1" -gt "$USED0" ] && ok "storage used went up ($USED0 -> $USED1 bytes)" || bad "storage used did not go up ($USED0 -> $USED1)"
R=$(gql "$TX" 'query($h: String!, $o: String!) { blobDownloadUrl(hash: $h, ownerDid: $o, space: "private") { url } }' "$(v h=$CAS o=$UO)")
check "another user cannot get the owner's private file" "$R" '.errors != null and .data.blobDownloadUrl == null'
R=$(gql "$TO" 'mutation($to: String!, $c: String!) { sendMessage(toDid: $to, content: "Notes for the meeting", objectCas: $c, objectName: "meeting-notes.txt", objectMime: "text/plain") { id } }' "$(v to=$UM1 c=$CAS)")
check "send the file in a direct message" "$R" '.data.sendMessage.id != null'
sleep 1
R=$(gql "$TM1" 'query($d: String!) { conversation(withDid: $d, limit: 5) { id threadKey objectCas objectName } }' "$(v d=$UO)")
MID=$(echo "$R" | jq -r "[.data.conversation[] | select(.objectCas == \"$CAS\")][0].id")
MTK=$(echo "$R" | jq -r "[.data.conversation[] | select(.objectCas == \"$CAS\")][0].threadKey")
[ "$MID" != "null" ] && ok "${NAME[$M1]} received the file message" || bad "file message not received" "$R"
R=$(gql "$TM1" 'query($k: String!, $id: String!) { messageBlobUrl(threadKey: $k, id: $id) { url } }' "$(v k=$MTK id=$MID)")
check "${NAME[$M1]} can download the attached file" "$R" '.data.messageBlobUrl.url | startswith("http")'

section "6. Group: create, members, group chat"
R=$(gql "$TO" 'mutation { createCircle(name: "Project Team", visibility: "private") { circleId name myRole } }')
check "${NAME[$O]} creates group 'Project Team'" "$R" '.data.createCircle.circleId != null'
CIR=$(echo "$R" | jq -r .data.createCircle.circleId)
for m in "${MEM[@]}"; do
  R=$(gql "$TO" 'mutation($c: String!, $m: String!) { addMember(circleId: $c, memberDid: $m) { memberDid role status } }' "$(v c=$CIR m=$(did ${NAME[$m]}))")
  check "add ${NAME[$m]} to the group" "$R" '.data.addMember.memberDid != null'
done
R=$(gql "$TO" 'query($c: String!) { circleMembers(circleId: $c) { memberDid role status } }' "$(v c=$CIR)")
check "group has $(( ${#MEM[@]} + 1 )) members" "$R" "(.data.circleMembers | length) == $(( ${#MEM[@]} + 1 ))"
R=$(gql "$TO" 'mutation($c: String!) { sendCircleMessage(circleId: $c, content: "Welcome to the Project Team group") { id } }' "$(v c=$CIR)")
check "group message from the owner" "$R" '.data.sendCircleMessage.id != null'
R=$(gql "$TM1" 'mutation($c: String!) { sendCircleMessage(circleId: $c, content: "Thanks!") { id } }' "$(v c=$CIR)")
check "group message from a member" "$R" '.data.sendCircleMessage.id != null'
R=$(gql "$TX" 'query($c: String!) { circleMessages(circleId: $c, limit: 5) { content } }' "$(v c=$CIR)")
check "${NAME[$X]} (not a member) cannot read the group" "$R" '.errors != null and ((.data.circleMessages // []) | length) == 0'

section "7. Calendar"
D1=$(date -d "tomorrow" +%F); F0=$(date +%Y-%m-%dT00:00:00+05:30); T0=$(date -d "+45 days" +%Y-%m-%dT00:00:00+05:30)
S=${D1}T11:00:00+05:30; E=${D1}T11:30:00+05:30
LINK="https://meet.jit.si/przma-project-sync-$RANDOM"
R=$(gql "$TO" '{ myCalendars { calendarId name calendarType isDefault myRole } }')
check "default personal calendar exists" "$R" '[.data.myCalendars[] | select(.isDefault)] | length == 1'
PCAL=$(echo "$R" | jq -r '[.data.myCalendars[] | select(.isDefault)][0].calendarId')
R=$(gql "$TO" 'mutation { createCalendar(name: "Project Team", calendarType: "business", color: "#3366ff", region: "IN_TN") { calendarId name calendarType } }')
check "create business calendar 'Project Team'" "$R" '.data.createCalendar.calendarId != null'
CAL=$(echo "$R" | jq -r .data.createCalendar.calendarId)
R=$(gql "$TO" 'mutation($c: String!, $s: String!, $e: String!, $l: String!) { createEvent(calendarId: $c, input: {
  title: "Project sync", description: "Weekly status", location: $l, notes: "Bring the demo",
  startsAt: $s, endsAt: $e, reminders: [10, 60] }) { eventId title location reminders } }' "$(v c=$CAL s=$S e=$E l=$LINK)")
check "schedule meeting with link + reminders" "$R" '.data.createEvent.eventId != null and (.data.createEvent.reminders | length) == 2'
EV=$(echo "$R" | jq -r .data.createEvent.eventId)
MON=$(date -d "next monday" +%F)
R=$(gql "$TO" 'mutation($c: String!, $s: String!, $e: String!) { createEvent(calendarId: $c, input: {
  title: "Monday stand-up", location: "https://meet.jit.si/przma-standup", startsAt: $s, endsAt: $e,
  recurrence: { freq: "weekly", byDay: ["MO"], count: 4 } }) { eventId isRecurring } }' "$(v c=$CAL s=${MON}T10:00:00+05:30 e=${MON}T10:30:00+05:30)")
check "weekly recurring meeting (4 Mondays)" "$R" '.data.createEvent.isRecurring == true'
EV2=$(echo "$R" | jq -r .data.createEvent.eventId)
R=$(gql "$TO" 'query($c: String!, $f: String!, $t: String!) { calendarEvents(calendarId: $c, from: $f, to: $t) { title occurrenceStart } }' "$(v c=$CAL f=$F0 t=$T0)")
check "calendarEvents: 1 meeting + 4 stand-ups" "$R" '([.data.calendarEvents[] | select(.title == "Monday stand-up")] | length) == 4 and ([.data.calendarEvents[] | select(.title == "Project sync")] | length) == 1'
R=$(gql "$TO" 'mutation($c: String!, $s: String!, $e: String!) { createEvent(calendarId: $c, input: {title: "Doctor visit (private)", startsAt: $s, endsAt: $e}) { eventId } }' "$(v c=$PCAL s=${D1}T17:00:00+05:30 e=${D1}T17:30:00+05:30)")
PEV=$(echo "$R" | jq -r .data.createEvent.eventId)
R=$(gql "$TM1" 'query($c: String!, $e: String!) { calendarEvent(calendarId: $c, eventId: $e) { title } }' "$(v c=$PCAL e=$PEV)")
check "private calendar not visible to ${NAME[$M1]}" "$R" '.errors != null and .data.calendarEvent == null'
R=$(gql "$TO" 'mutation($c: String!, $g: String!) { shareCalendarWithCircle(calendarId: $c, circleId: $g, role: "viewer") { targetType role } }' "$(v c=$CAL g=$CIR)")
check "share calendar with the group (viewer)" "$R" '.data.shareCalendarWithCircle.role == "viewer"'
R=$(gql "$TO" 'mutation($c: String!, $u: String!) { shareCalendarWithUser(calendarId: $c, userDid: $u, role: "editor") { targetType role } }' "$(v c=$CAL u=$UX)")
check "share calendar with ${NAME[$X]} (editor)" "$R" '.data.shareCalendarWithUser.role == "editor"'
R=$(gql "$TM1" '{ myCalendars { calendarId myRole } }')
check "${NAME[$M1]} sees the calendar through the group as viewer" "$R" "[.data.myCalendars[] | select(.calendarId == \"$CAL\" and .myRole == \"viewer\")] | length == 1"
R=$(gql "$TX" '{ myCalendars { calendarId myRole } }')
check "${NAME[$X]} sees the calendar as editor" "$R" "[.data.myCalendars[] | select(.calendarId == \"$CAL\" and .myRole == \"editor\")] | length == 1"
R=$(gql "$TM1" 'mutation($c: String!, $e: String!) { updateEvent(calendarId: $c, eventId: $e, input: {description: "edited by viewer"}) { description } }' "$(v c=$CAL e=$EV)")
check "viewer cannot edit the meeting" "$R" '.errors != null and .data.updateEvent == null'
R=$(gql "$TX" 'mutation($c: String!, $e: String!) { updateEvent(calendarId: $c, eventId: $e, input: {description: "Agenda added by editor"}) { description } }' "$(v c=$CAL e=$EV)")
check "editor can edit the meeting" "$R" '.data.updateEvent.description == "Agenda added by editor"'
INV=$(for i in "${OTHERS[@]}"; do echo -n "\"$(did ${NAME[$i]})\","; done | sed 's/,$//')
R=$(gql "$TO" "mutation(\$c: String!, \$e: String!) { inviteToEvent(calendarId: \$c, eventId: \$e, userDids: [$INV]) { inviteeDid rsvp } }" "$(v c=$CAL e=$EV)")
check "invite all $((N-1)) people to the meeting" "$R" "(.data.inviteToEvent | length) == $((N-1))"
RESP=(accepted tentative declined accepted accepted accepted)
k=0; for i in "${OTHERS[@]}"; do
  R=$(gql "$(tk $i)" 'mutation($c: String!, $e: String!, $r: String!) { rsvpEvent(calendarId: $c, eventId: $e, response: $r) }' "$(v c=$CAL e=$EV r=${RESP[$k]})")
  check "${NAME[$i]} RSVP ${RESP[$k]}" "$R" '.data.rsvpEvent == true'; k=$((k+1))
done
R=$(gql "$TO" 'query($c: String!, $e: String!) { eventInvites(calendarId: $c, eventId: $e) { inviteeDid rsvp } }' "$(v c=$CAL e=$EV)")
check "organiser sees every RSVP" "$R" '([.data.eventInvites[] | select(.rsvp != "pending")] | length) >= 3'
R=$(gql "$TM1" '{ notifications(limit: 20) { activityType category } }')
check "${NAME[$M1]} has notifications" "$R" '(.data.notifications | length) >= 1'
R=$(gql "$TO" 'mutation($to: String!, $m: String!) { sendMessage(toDid: $to, content: $m) { id } }' "$(v to=$UX m="Project sync tomorrow 11:00 - $LINK")")
check "meeting link shared by direct message to ${NAME[$X]}" "$R" '.data.sendMessage.id != null'
R=$(gql "$TO" 'mutation($c: String!, $m: String!) { sendCircleMessage(circleId: $c, content: $m) { id } }' "$(v c=$CIR m="Project sync tomorrow 11:00 - $LINK")")
check "meeting link shared in the group chat" "$R" '.data.sendCircleMessage.id != null'
sleep 1
R=$(gql "$TX" 'query($d: String!) { conversation(withDid: $d, limit: 5) { content } }' "$(v d=$UO)")
check "${NAME[$X]} got the link by DM" "$R" "[.data.conversation[] | select(.content | test(\"$LINK\"))] | length >= 1"
for m in "${MEM[@]}"; do
  R=$(gql "$(tk $m)" 'query($c: String!) { circleMessages(circleId: $c, limit: 10) { content } }' "$(v c=$CIR)")
  check "${NAME[$m]} sees the link in the group" "$R" "[.data.circleMessages[] | select(.content | test(\"$LINK\"))] | length >= 1"
done
R=$(gql "$TM1" 'query($f: String!, $t: String!) { myAgenda(from: $f, to: $t) { title location } }' "$(v f=$F0 t=$T0)")
check "${NAME[$M1]}'s agenda shows the meeting with its link" "$R" "[.data.myAgenda[] | select(.title == \"Project sync\" and .location == \"$LINK\")] | length >= 1"
R=$(gql "$TO" 'mutation($c: String!, $e: String!) { setPrivateNote(calendarId: $c, eventId: $e, text: "Ask about budget") }' "$(v c=$CAL e=$EV)")
check "private note" "$R" '.errors == null'
R=$(gql "$TO" 'query($c: String!, $e: String!) { calendarEvent(calendarId: $c, eventId: $e) { myNote } }' "$(v c=$CAL e=$EV)")
check "organiser sees own note" "$R" '.data.calendarEvent.myNote == "Ask about budget"'
R=$(gql "$TX" 'query($c: String!, $e: String!) { calendarEvent(calendarId: $c, eventId: $e) { myNote } }' "$(v c=$CAL e=$EV)")
check "another user does not see that note" "$R" '.data.calendarEvent.myNote != "Ask about budget"'
R=$(gql "$TO" 'mutation($c: String!, $e: String!, $o: String!) { skipOccurrence(calendarId: $c, eventId: $e, occurrenceStart: $o) }' "$(v c=$CAL e=$EV2 o=${MON}T10:00:00+05:30)")
check "skip one Monday" "$R" '.data.skipOccurrence == true'
R=$(gql "$TO" 'query($c: String!, $f: String!, $t: String!) { calendarEvents(calendarId: $c, from: $f, to: $t) { title } }' "$(v c=$CAL f=$F0 t=$T0)")
check "3 stand-ups left" "$R" '([.data.calendarEvents[] | select(.title == "Monday stand-up")] | length) == 3'
R=$(gql "$TO" 'mutation($c: String!, $s: String!, $e: String!) { createEvent(calendarId: $c, input: {title: "Temp meeting", startsAt: $s, endsAt: $e}) { eventId } }' "$(v c=$CAL s=${D1}T15:00:00+05:30 e=${D1}T15:30:00+05:30)")
TEV=$(echo "$R" | jq -r .data.createEvent.eventId)
R=$(gql "$TO" 'mutation($c: String!, $e: String!) { cancelEvent(calendarId: $c, eventId: $e) }' "$(v c=$CAL e=$TEV)")
check "cancel a meeting" "$R" '.data.cancelEvent == true'
R=$(gql "$TO" 'query($f: String!, $t: String!) { holidays(region: "IN_TN", from: $f, to: $t) { title startsAt } }' "$(v f=$(date +%Y-%m-%dT00:00:00+05:30) t=$(date -d '+60 days' +%Y-%m-%dT00:00:00+05:30))")
check "holidays query works ($(echo "$R" | jq '.data.holidays | length') found; 0 = list not loaded)" "$R" '.errors == null'
R=$(gql "$TO" 'mutation($c: String!, $g: String!) { unshareCalendar(calendarId: $c, circleId: $g) }' "$(v c=$CAL g=$CIR)")
check "unshare from the group" "$R" '.data.unshareCalendar == true'
R=$(gql "$TM1" '{ myCalendars { calendarId } }')
check "group member no longer sees the calendar" "$R" "[.data.myCalendars[] | select(.calendarId == \"$CAL\")] | length == 0"

section "8. Which API each user may call"
printf "  %-10s %-11s %-18s %-20s %-14s\n" USER ROLE createAccessKey adminSecurityEvents myAccess
for i in $(seq 0 $((N-1))); do
  t=$(tk $i)
  K=$(gql "$t" 'mutation { createAccessKey(name: "role-check", scopes: ["calendar:read"], days: 1) { key accessKey { id } } }')
  A=$(gql "$t" '{ adminSecurityEvents(limit: 1) { eventType } }')
  M=$(gql "$t" '{ myAccess { plan } }')
  kres=$(echo "$K" | jq -r 'if .data.createAccessKey.key then "allowed" else .errors[0].message end')
  ares=$(echo "$A" | jq -r 'if .data.adminSecurityEvents then "allowed" else .errors[0].message end')
  mres=$(echo "$M" | jq -r 'if .data.myAccess then "allowed" else .errors[0].message end')
  printf "  %-10s %-11s %-18s %-20s %-14s\n" "${NAME[$i]}" "${ROLE[$i]}" "$kres" "$ares" "$mres"
  if [ "${ROLE[$i]}" = basic ]; then
    [ "$kres" = scope_denied ] && ok "${NAME[$i]} (basic) cannot create access keys" || bad "${NAME[$i]} basic createAccessKey" "$K"
  else
    [ "$kres" = allowed ] && ok "${NAME[$i]} (privileged) can create access keys" || bad "${NAME[$i]} privileged createAccessKey" "$K"
    kid=$(echo "$K" | jq -r '.data.createAccessKey.accessKey.id // empty')
    [ -n "$kid" ] && gql "$t" 'mutation($id: String!) { revokeAccessKey(id: $id) }' "$(v id=$kid)" >/dev/null
  fi
  [ "$mres" = allowed ] && ok "${NAME[$i]} myAccess allowed" || bad "${NAME[$i]} myAccess" "$M"
  if [ "${NAME[$i]}" != "$ADMIN_USER" ]; then
    [ "$ares" = scope_denied ] && ok "${NAME[$i]} cannot call admin APIs" || bad "${NAME[$i]} admin API" "$A"
  fi
done
R=$(gql "$TO" 'mutation { adminSetPlan(did: "did:przma:nobody", plan: "business") { plan } }')
check "non-admin adminSetPlan -> scope_denied with needed admin:*" "$R" '.errors[0].message == "scope_denied" and .errors[0].extensions.needed == "admin:*"'

section "9. Access keys (privileged user)"
if [ ${#PRIV[@]} -ge 1 ]; then
  P=${PRIV[0]}; TP=$(tk $P)
  R=$(gql "$TP" 'mutation { createAccessKey(name: "My CRM", scopes: ["calendar:read"], days: 30) { key accessKey { id keyPrefix expiresAt } } }')
  check "${NAME[$P]} creates key (calendar:read, 30 days)" "$R" '.data.createAccessKey.key | startswith("pk_live_")'
  KEY=$(echo "$R" | jq -r .data.createAccessKey.key); KID=$(echo "$R" | jq -r .data.createAccessKey.accessKey.id)
  R=$(gql "$TP" 'mutation { createAccessKey(name: "too long", scopes: ["calendar:read"], days: 365) { key } }')
  check "key over the role's day limit refused" "$R" '.errors[0].message | test("days must be")'
  R=$(gql "$TP" 'mutation { createAccessKey(name: "admin", scopes: ["admin:*"], days: 5) { key } }')
  check "key with a scope the owner lacks refused" "$R" '.errors[0].message == "scope_not_held_by_owner"'
  R=$(gqlk "$KEY" '{ myCalendars { calendarId } }')
  check "key: myCalendars (read) allowed" "$R" '.data.myCalendars != null'
  R=$(gqlk "$KEY" 'mutation { createCalendar(name: "via key") { calendarId } }')
  check "key: createCalendar (write) refused" "$R" '.errors[0].message == "scope_denied"'
  R=$(gqlk "$KEY" 'mutation($to: String!) { sendMessage(toDid: $to, content: "via key") { id } }' "$(v to=$UO)")
  check "key: sendMessage (chat) refused" "$R" '.errors[0].message == "scope_denied"'
  http GET /api/v1/profile "X-API-Key: $KEY"
  check_code "key: REST /api/v1/profile -> 403" "$CODE" 403 "$BODY"
  R=$(gql "$TP" '{ myAccessKeys { name keyPrefix revokedAt } }')
  check "myAccessKeys lists the key (no secret)" "$R" '[.data.myAccessKeys[] | select(.name == "My CRM")] | length >= 1'
  R=$(gql "$TP" 'mutation($id: String!) { revokeAccessKey(id: $id) }' "$(v id=$KID)")
  check "revoke the key" "$R" '.data.revokeAccessKey == true'
  http GET /api/v1/search/stats "X-API-Key: $KEY"
  check_code "revoked key -> 401" "$CODE" 401 "$BODY"
else
  info "no privileged user: access-key tests skipped"
fi

section "10. Sessions and rate limit"
R=$(gql "$TO" '{ mySessions { sid device current lastSeenAt } }')
check "mySessions shows the current login" "$R" '[.data.mySessions[] | select(.current)] | length == 1'
LAST=$(tk $((N-1))); hit=""
for n in $(seq 1 12); do
  R=$(gql "$LAST" 'mutation { completeRegistration { status } }')
  echo "$R" | jq -e '.errors[0].message == "rate_limited"' >/dev/null 2>&1 && { hit=$n; break; }
done
[ -n "$hit" ] && ok "completeRegistration rate limit (10/min) hit at call $hit" || bad "rate limit never hit"

section "11. Admin ($ADMIN_USER)"
R=$(gql "$TA" '{ adminSecurityEvents(limit: 1) { eventType } }')
if ! echo "$R" | jq -e '.data.adminSecurityEvents' >/dev/null 2>&1 && [ -n "${AUTHZ_DATABASE_URL:-}" ] && command -v psql >/dev/null; then
  psql "$AUTHZ_DATABASE_URL" -qc "insert into przma_authz.user_roles (did, role_code, granted_by) values ('$(did $ADMIN_USER)', 'platform_admin', 'e2e-script') on conflict do nothing;" \
    && info "made $ADMIN_USER platform_admin (waiting 65 s for the cache)" && sleep 65
  R=$(gql "$TA" '{ adminSecurityEvents(limit: 1) { eventType } }')
fi
if echo "$R" | jq -e '.data.adminSecurityEvents' >/dev/null 2>&1; then
  R=$(gql "$TA" '{ adminSecurityEvents(limit: 8) { createdAt eventType severity did details actionTaken } }')
  check "adminSecurityEvents" "$R" '(.data.adminSecurityEvents | length) >= 1'
  echo "$R" | jq -r '.data.adminSecurityEvents[] | "    \(.createdAt)  \(.eventType)  \(.did // "-")  \(.details | fromjson | .api // "")  \(.actionTaken)"'
  R=$(gql "$TA" 'query($d: String!) { adminAccount(did: $d) { plan roles usedBytes quotaBytes storage { bucket } } }' "$(v d=$UO)")
  check "adminAccount ${NAME[$O]}" "$R" '.data.adminAccount.plan != null'
  if [ "${ADMIN_TESTS:-0}" = "1" ] && [ ${#BASIC[@]} -ge 1 ]; then
    B=${BASIC[-1]}; UB=$(did ${NAME[$B]})
    R=$(gql "$TA" 'mutation($d: String!) { adminSetPlan(did: $d, plan: "premium") { plan role storage } }' "$(v d=$UB)")
    check "upgrade ${NAME[$B]}: basic -> privileged ($(echo "$R" | jq -r .data.adminSetPlan.storage))" "$R" '.data.adminSetPlan.role == "privileged_user"'
    sleep 20
    R=$(gql "$(tk $B)" '{ myAccess { roles quotaBytes storage { tier bucket status } } }')
    check "${NAME[$B]} now privileged, tier 2, own bucket ready (same token, no logout)" "$R" '.data.myAccess.roles == ["privileged_user"] and .data.myAccess.storage.tier == 2 and .data.myAccess.storage.status == "ready"'
    R=$(gql "$(tk $B)" 'mutation { createAccessKey(name: "after upgrade", scopes: ["calendar:read"], days: 5) { key accessKey { id } } }')
    check "${NAME[$B]} can now create access keys" "$R" '.data.createAccessKey.key | startswith("pk_live_")'
    R=$(gql "$(tk $B)" '{ myCalendars { calendarId } }')
    check "${NAME[$B]}'s calendars still there after the storage move" "$R" '(.data.myCalendars | length) >= 1'
    R=$(gql "$TA" 'mutation($d: String!) { adminSetPlan(did: $d, plan: "free") { plan role storage } }' "$(v d=$UB)")
    check "downgrade ${NAME[$B]} back to free" "$R" '.data.adminSetPlan.role == "basic_user"'
    R=$(gql "$(tk $B)" 'mutation { createAccessKey(name: "after downgrade", scopes: ["calendar:read"], days: 5) { key } }')
    check "${NAME[$B]} cannot create keys again" "$R" '.errors[0].message == "scope_denied"'
    R=$(gql "$TA" 'mutation($d: String!) { adminSetAccountStatus(did: $d, status: "suspended", reason: "e2e") { status } }' "$(v d=$UB)")
    check "suspend ${NAME[$B]}" "$R" '.data.adminSetAccountStatus.status == "suspended"'
    R=$(gql "$(tk $B)" '{ myCalendars { calendarId } }')
    check "suspended user refused (account_suspended)" "$R" '.errors[0].message == "account_suspended"'
    gql "$TA" 'mutation($d: String!) { adminSetAccountStatus(did: $d, status: "active") { status } }' "$(v d=$UB)" >/dev/null
    NT=$(tok "${NAME[$B]}"); R=$(gql "$NT" '{ myCalendars { calendarId } }')
    check "reactivated + new login works" "$R" '.data.myCalendars != null'
  else
    echo "  (ADMIN_TESTS=1 adds: upgrade a basic user to privileged and back, suspend and reactivate)"
  fi
else
  info "$ADMIN_USER is not platform_admin. Run: psql \"\$AUTHZ_DATABASE_URL\" -c \"insert into przma_authz.user_roles (did, role_code, granted_by) values ('$(did $ADMIN_USER)', 'platform_admin', 'manual') on conflict do nothing;\""
fi

section "12. Rows in the central tables"
if [ -n "${AUTHZ_DATABASE_URL:-}" ] && command -v psql >/dev/null; then
  sleep 31
  IN=$(for i in $(seq 0 $((N-1))); do echo -n "'$(did ${NAME[$i]})',"; done | sed 's/,$//')
  psql "$AUTHZ_DATABASE_URL" -c "select a.did, a.status, a.plan_code, string_agg(r.role_code, ',') roles, s.storage_tier tier, s.bucket, u.used_bytes from przma_authz.accounts a left join przma_authz.user_roles r on r.did = a.did left join przma_authz.storage_locations s on s.did = a.did left join przma_authz.storage_usage u on u.did = a.did where a.did in ($IN) group by 1,2,3,5,6,7 order by 1;"
  psql "$AUTHZ_DATABASE_URL" -c "select did, service, api_calls, errors, bytes_written from przma_authz.usage_daily where day = current_date and did in ($IN) order by 1, 2;"
  psql "$AUTHZ_DATABASE_URL" -c "select event_type, count(*) from przma_authz.security_events where created_at > now() - interval '1 hour' group by 1 order by 2 desc;"
  psql "$AUTHZ_DATABASE_URL" -c "select action, count(*) from przma_authz.audit_log where created_at > now() - interval '1 hour' group by 1 order by 1;"
  psql "$AUTHZ_DATABASE_URL" -c "select did, count(*) filter (where revoked_at is null) active, count(*) total from przma_authz.sessions where did in ($IN) group by 1 order by 1;"
else
  info "set AUTHZ_DATABASE_URL (and install psql) to print the table rows here"
fi

rm -rf "$TMPD"
echo; echo "=== RESULT: $PASS passed, $FAIL failed, $INFO info ==="
