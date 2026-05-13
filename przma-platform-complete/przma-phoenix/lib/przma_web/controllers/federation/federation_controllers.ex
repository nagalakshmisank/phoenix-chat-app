# lib/przma_web/controllers/federation/activitypub_controller.ex
#
# ActivityPub endpoints: actor, inbox, outbox, events.
# Served at /ap/* — these are public-facing federation endpoints.

defmodule PRZMAWeb.Federation.ActivityPubController do
  use PRZMAWeb, :controller

  alias PRZMA.Calendar.Federation.{ActivityPub, HTTPSignature}
  alias PRZMA.Calendar.Events

  # ── ACTOR DOCUMENT ────────────────────────────────────────────────────────

  # GET /ap/actor/:did
  # Returns ActivityPub Person document for a DID
  def actor(conn, %{"did" => encoded_did}) do
    did = URI.decode(encoded_did)

    case ActivityPub.actor_document(did) do
      {:ok, actor} ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> json(actor)

      {:error, _} ->
        conn |> put_status(:not_found) |> json(%{error: "Actor not found"})
    end
  end

  # ── INBOX ─────────────────────────────────────────────────────────────────

  # POST /ap/inbox/:did
  # Receives inbound ActivityPub objects.
  # Verifies HTTP Signature before processing.
  def inbox(conn, %{"did" => encoded_did}) do
    did  = URI.decode(encoded_did)
    body = conn.assigns[:raw_body] || ""

    # Parse and verify
    with {:ok, sender_did}  <- HTTPSignature.verify_request(conn),
         {:ok, activity}    <- Jason.decode(body) do

      # Process asynchronously via Oban
      PRZMA.Calendar.Jobs.APInboxProcessor.enqueue(did, activity, sender_did)

      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(202, Jason.encode!(%{accepted: true}))
    else
      {:error, reason} ->
        require Logger
        Logger.warning("AP inbox rejected",
          did: did, reason: inspect(reason))
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Signature verification failed"})
    end
  end

  # ── OUTBOX ────────────────────────────────────────────────────────────────

  # GET /ap/outbox/:did
  def outbox(conn, %{"did" => encoded_did} = params) do
    did  = URI.decode(encoded_did)
    page = String.to_integer(params["page"] || "1")

    case ActivityPub.outbox(did, page) do
      {:ok, collection} ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> json(collection)

      {:error, _} ->
        conn |> put_status(:not_found) |> json(%{error: "Outbox not found"})
    end
  end

  # ── EVENT OBJECT ──────────────────────────────────────────────────────────

  # GET /ap/events/:id
  # Returns a specific ActivityPub Event object
  def event(conn, %{"id" => id}) do
    # Look up event by AP object ID or internal ID
    case find_event_by_ap_id(id) do
      {:ok, event} ->
        {:ok, obj} = ActivityPub.build_event_object_public(event)
        conn
        |> put_resp_content_type("application/activity+json")
        |> json(obj)

      {:error, _} ->
        conn |> put_status(:not_found) |> json(%{error: "Event not found"})
    end
  end

  # ── WEBFINGER ─────────────────────────────────────────────────────────────

  # GET /.well-known/webfinger?resource=acct:alice@alice.przma.net
  def webfinger(conn, %{"resource" => resource}) do
    case parse_webfinger_resource(resource) do
      {:ok, did, instance_url} ->
        json(conn, %{
          subject: resource,
          aliases: [did],
          links: [
            %{
              rel:  "self",
              type: "application/activity+json",
              href: "#{instance_url}/ap/actor/#{URI.encode(did)}",
            }
          ]
        })

      {:error, _} ->
        conn |> put_status(:not_found) |> json(%{error: "Resource not found"})
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp find_event_by_ap_id(_id) do
    {:error, :not_implemented}  # Phase 4: query by ap_object_id
  end

  defp parse_webfinger_resource("acct:" <> rest) do
    case String.split(rest, "@") do
      [_name, domain] ->
        {:ok, "did:web:#{domain}", "https://#{domain}"}
      _ ->
        {:error, :invalid_resource}
    end
  end
  defp parse_webfinger_resource(_), do: {:error, :invalid_resource}
end

# ─── CALDAV CONTROLLER ───────────────────────────────────────────────────────

defmodule PRZMAWeb.Federation.CalDAVController do
  use PRZMAWeb, :controller

  alias PRZMA.Calendar.Federation.ICal
  alias PRZMA.Calendar.Events

  # ── WELL-KNOWN REDIRECT ───────────────────────────────────────────────────

  # GET /.well-known/caldav
  def well_known(conn, _params) do
    conn
    |> put_resp_header("location", "/caldav/principal/")
    |> send_resp(301, "")
  end

  # ── PRINCIPAL (PROPFIND) ─────────────────────────────────────────────────

  # PROPFIND /caldav/principal/:did
  def principal(conn, %{"did" => did}) do
    instance_url = Application.get_env(:przma, [:instance, :url], "https://przma.ai")
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>/caldav/principal/#{URI.encode(did)}</D:href>
        <D:propstat>
          <D:prop>
            <D:displayname>#{did}</D:displayname>
            <C:calendar-home-set>
              <D:href>/caldav/calendars/#{URI.encode(did)}/</D:href>
            </C:calendar-home-set>
            <D:principal-URL>
              <D:href>/caldav/principal/#{URI.encode(did)}</D:href>
            </D:principal-URL>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
    conn
    |> put_resp_content_type("application/xml; charset=utf-8")
    |> send_resp(207, xml)
  end

  # ── CALENDAR LIST (PROPFIND) ─────────────────────────────────────────────

  # PROPFIND /caldav/calendars/:did/
  def calendar_list(conn, %{"did" => did}) do
    {:ok, calendars} = ICal.list_calendars(did)

    cal_xml = Enum.map_join(calendars, "\n", fn cal ->
      """
      <D:response>
        <D:href>/caldav/calendars/#{URI.encode(did)}/#{cal.id}/</D:href>
        <D:propstat>
          <D:prop>
            <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
            <D:displayname>#{cal.name}</D:displayname>
            <C:supported-calendar-component-set>
              #{Enum.map_join(cal.supported, "", fn s -> "<C:comp name=\"#{s}\"/>" end)}
            </C:supported-calendar-component-set>
            <C:calendar-description>#{cal.description}</C:calendar-description>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
      """
    end)

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      #{cal_xml}
    </D:multistatus>
    """
    conn
    |> put_resp_content_type("application/xml; charset=utf-8")
    |> send_resp(207, xml)
  end

  # ── CALENDAR GET ─────────────────────────────────────────────────────────

  # GET /caldav/calendars/:did/:calendar_id/
  def calendar_get(conn, %{"did" => did, "calendar_id" => cal_id} = params) do
    space    = calendar_id_to_space(cal_id)
    start_dt = parse_dt(params["start"])
    end_dt   = parse_dt(params["end"])
    timezone = params["timezone"] || "UTC"

    case ICal.export(did,
          space:        space,
          start:        start_dt,
          end:          end_dt,
          timezone:     timezone,
          calendar_name: cal_id) do
      {:ok, ical_str} ->
        conn
        |> put_resp_content_type("text/calendar; charset=utf-8")
        |> put_resp_header("content-disposition",
            "attachment; filename=\"#{cal_id}.ics\"")
        |> send_resp(200, ical_str)

      {:error, msg} ->
        conn |> put_status(:not_found) |> json(%{error: msg})
    end
  end

  # ── EVENT PUT (CalDAV UPSERT) ─────────────────────────────────────────────

  # PUT /caldav/calendars/:did/:calendar_id/:uid.ics
  def event_put(conn, %{"did" => did, "uid" => uid}) do
    ical_str = conn.assigns[:raw_body] || ""

    case ICal.import_vevent(did, ical_str, uid) do
      {:ok, event} ->
        conn
        |> put_resp_header("etag", "\"#{event["version"]}\"")
        |> send_resp(201, "")

      {:error, msg} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  # ── EVENT DELETE (CalDAV DELETE) ──────────────────────────────────────────

  # DELETE /caldav/calendars/:did/:calendar_id/:uid.ics
  def event_delete(conn, %{"did" => did, "uid" => uid}) do
    # Find event by ical_uid and cancel it
    case Events.find_by_ical_uid(did, uid) do
      {:ok, event} ->
        Events.cancel(did, event["id"], event["space"])
        send_resp(conn, 204, "")

      {:error, _} ->
        conn |> put_status(:not_found) |> json(%{error: "Event not found"})
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp calendar_id_to_space("personal"),   do: "core"
  defp calendar_id_to_space("core"),        do: "core"
  defp calendar_id_to_space("circle-" <> c), do: "circle:#{c}"
  defp calendar_id_to_space(other),        do: other

  defp parse_dt(nil), do: nil
  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _            -> nil
    end
  end
end
