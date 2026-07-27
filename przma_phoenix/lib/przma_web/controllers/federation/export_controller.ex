# lib/przma_web/controllers/calendar/export_controller.ex
#
# Calendar export endpoint — iCal format.

defmodule PRZMAWeb.Calendar.ExportController do
  use PRZMAWeb, :controller

  alias PRZMA.Calendar.Federation.ICal

  # GET /api/v1/calendar/export
  # Params: space, start, end, format (ical | json), timezone, include_tasks
  def export(conn, params) do
    did      = conn.assigns.did
    format   = params["format"] || "ical"
    space    = params["space"]  || "core"
    start_dt = parse_dt(params["start"])
    end_dt   = parse_dt(params["end"])
    timezone = params["timezone"] || "UTC"
    inc_task = params["include_tasks"] != "false"

    case format do
      "ical" ->
        case ICal.export(did,
              space:        space,
              start:        start_dt,
              end:          end_dt,
              timezone:     timezone,
              include_tasks: inc_task) do
          {:ok, ical_str} ->
            filename = "przma-calendar-#{Date.utc_today()}.ics"
            conn
            |> put_resp_content_type("text/calendar; charset=utf-8")
            |> put_resp_header("content-disposition",
                ~s(attachment; filename="#{filename}"))
            |> send_resp(200, ical_str)

          {:error, msg} ->
            conn |> put_status(:internal_server_error) |> json(%{error: msg})
        end

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "Unsupported format: #{format}"})
    end
  end

  defp parse_dt(nil), do: nil
  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _            -> nil
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Router additions for Phase 3 federation routes
# Add these to the existing router.ex

defmodule PRZMAWeb.Router.Phase3 do
  @moduledoc """
  Federation route additions for Phase 3.
  Paste these scopes into PRZMAWeb.Router.

  scope "/api/v1/calendar", PRZMAWeb.Calendar do
    pipe_through [:api, :require_did_auth]

    # Export
    get "/export", ExportController, :export

    # Publish event to Commons via ActivityPub
    post "/events/:id/publish",   EventController, :publish
    post "/events/:id/unpublish", EventController, :unpublish
  end

  scope "/.well-known", PRZMAWeb.Federation do
    pipe_through :api
    get "/webfinger",  ActivityPubController, :webfinger
    get "/caldav",     CalDAVController, :well_known
  end

  scope "/ap", PRZMAWeb.Federation do
    pipe_through :api
    get  "/actor/:did",   ActivityPubController, :actor
    post "/inbox/:did",   ActivityPubController, :inbox
    get  "/outbox/:did",  ActivityPubController, :outbox
    get  "/events/:id",   ActivityPubController, :event
  end

  scope "/caldav", PRZMAWeb.Federation do
    pipe_through :api
    match :propfind, "/principal/:did",            CalDAVController, :principal
    match :propfind, "/calendars/:did/",           CalDAVController, :calendar_list
    get   "/calendars/:did/:calendar_id/",         CalDAVController, :calendar_get
    put   "/calendars/:did/:calendar_id/:uid.ics", CalDAVController, :event_put
    delete "/calendars/:did/:calendar_id/:uid.ics",CalDAVController, :event_delete
  end
  """
end
