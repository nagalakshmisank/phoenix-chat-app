# lib/przma_web/plugs/did_auth.ex
#
# Plug that verifies DID-based HTTP Signature authentication.
# Sets conn.assigns.did on success.
# Returns 401 on failure.

defmodule PRZMAWeb.Plugs.DIDAuth do
  import Plug.Conn
  alias PRZMA.Identity

  def init(opts), do: opts

  def call(conn, _opts) do
    case Identity.verify_http_signature(conn) do
      {:ok, did} ->
        assign(conn, :did, did)

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized: #{reason}"}))
        |> halt()
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/przma_web/plugs/calendar_permissions.ex
#
# Plug that enforces circle-level calendar permissions.
# Requires conn.assigns.did to be set (run after DIDAuth).
# Requires conn.params["circle_did"] to identify the circle.

defmodule PRZMAWeb.Plugs.CalendarPermissions do
  import Plug.Conn
  alias PRZMA.Identity
  alias PRZMA.Calendar.Governance

  def init(action), do: action

  @doc """
  Use in router pipeline or individual actions:

    plug PRZMAWeb.Plugs.CalendarPermissions, :create_content
    plug PRZMAWeb.Plugs.CalendarPermissions, :share_to_circle
  """
  def call(conn, action) do
    did        = conn.assigns[:did]
    circle_did = conn.params["circle_did"] || conn.path_params["circle_did"]

    cond do
      is_nil(circle_did) ->
        # Not a circle route — no circle permission needed
        conn

      true ->
        case Identity.get_role(did, circle_did) do
          {:ok, role} ->
            if Governance.permitted?(role, action) do
              assign(conn, :circle_role, role)
            else
              deny(conn, action, role)
            end

          :error ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(403, Jason.encode!(%{
                error: "Not a member of this circle"
               }))
            |> halt()
        end
    end
  end

  defp deny(conn, action, role) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{
        error: "Permission denied",
        action: action,
        role:   role,
       }))
    |> halt()
  end
end
