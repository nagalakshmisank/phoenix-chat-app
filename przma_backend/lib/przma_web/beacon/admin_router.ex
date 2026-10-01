defmodule PRZMAWeb.Beacon.AdminRouter do
  @moduledoc """
  Routes of the Beacon admin endpoint (port 4300). Separate from
  PRZMAWeb.Router (the platform API), which is not changed.

      http://localhost:4300/admin               Beacon LiveAdmin home
      http://localhost:4300/admin/przma/users   Users & Activity (our page)
      http://localhost:4300/site                Beacon CMS site :przma (pages)

  To add a new admin page later (chat, calendar, services ...), write a
  LiveView in lib/przma_web/beacon/pages/ and add one line to
  `additional_pages` below.
  """
  use Phoenix.Router
  use Beacon.Router
  use Beacon.LiveAdmin.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_admin_auth do
    plug PRZMAWeb.Beacon.AdminBasicAuth
  end

  pipeline :beacon_admin do
    plug Beacon.LiveAdmin.Plug
  end

  pipeline :beacon do
    plug Beacon.Plug
  end

  # Admin UI — must stay ABOVE the beacon_site scope.
  scope "/" do
    pipe_through [:browser, :require_admin_auth, :beacon_admin]

    beacon_live_admin "/admin",
      additional_pages: [
        {"/users", PRZMAWeb.Beacon.Pages.UserActivityLive, :index}
      ]
  end

  # Beacon needs one site to manage. Mounted at /site and also behind login.
  scope "/" do
    pipe_through [:browser, :require_admin_auth, :beacon]
    beacon_site "/site", site: :przma
  end
end
