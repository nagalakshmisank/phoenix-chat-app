defmodule PRZMAWeb.ApiConsoleLive do
  @moduledoc """
  A small in-browser Postman-style console for exercising the przma-phoenix
  REST API (port 4000) while you develop. Pick a preset, edit any
  `<placeholder>` values, hit Send.

  Not meant for production — mount it only in dev, or protect the /console
  route before deploying anywhere public.
  """
  use PRZMAWeb, :live_view

  # ── Presets ────────────────────────────────────────────────────────────
  # auth: true  → endpoint requires the Bearer token (require_did_auth pipeline)

  @presets [
    # -- Auth --------------------------------------------------------------
    %{group: "Auth", label: "Register", method: "POST", auth: false,
      path: "/api/v1/account/register",
      body: ~s({\n  "nickname": "testuser1",\n  "email": "you@example.com",\n  "password": "password123"\n})},
    %{group: "Auth", label: "Verify email (OTP)", method: "POST", auth: false,
      path: "/api/v1/account/verify_email",
      body: ~s({\n  "nickname": "testuser1",\n  "code": "123456"\n})},
    %{group: "Auth", label: "Resend OTP", method: "POST", auth: false,
      path: "/api/v1/account/resend_otp",
      body: ~s({\n  "nickname": "testuser1"\n})},
    %{group: "Auth", label: "Forgot password", method: "POST", auth: false,
      path: "/api/v1/account/forgot_password",
      body: ~s({\n  "nickname": "testuser1",\n  "email": "you@example.com"\n})},
    %{group: "Auth", label: "Reset password", method: "POST", auth: false,
      path: "/api/v1/account/reset_password",
      body: ~s({\n  "nickname": "testuser1",\n  "token": "<reset_token>",\n  "password": "newpassword123",\n  "password_confirmation": "newpassword123"\n})},
    %{group: "Auth", label: "Login (get token)", method: "POST", auth: false,
      path: "/api/v1/oauth/token",
      body: ~s({\n  "grant_type": "password",\n  "username": "testuser1",\n  "password": "password123"\n})},
    %{group: "Auth", label: "Verify credentials (me)", method: "GET", auth: true,
      path: "/api/v1/accounts/verify_credentials", body: ""},
    %{group: "Auth", label: "Update settings", method: "PATCH", auth: true,
      path: "/api/v1/account/settings",
      body: ~s({\n  "bio": "hello from the console",\n  "is_private": false\n})},
    %{group: "Auth", label: "List sessions", method: "GET", auth: true,
      path: "/api/v1/sessions", body: ""},
    %{group: "Auth", label: "Revoke session", method: "DELETE", auth: true,
      path: "/api/v1/sessions/<session_id>", body: ""},
    %{group: "Auth", label: "Revoke all sessions", method: "DELETE", auth: true,
      path: "/api/v1/sessions", body: ""},
    %{group: "Auth", label: "Logout", method: "DELETE", auth: true,
      path: "/oauth/token", body: ""},

    # -- Circles -------------------------------------------------------------
    %{group: "Circles", label: "Create circle", method: "POST", auth: true,
      path: "/api/v1/circles",
      body: ~s({\n  "name": "Test Circle",\n  "description": "made from the console"\n})},
    %{group: "Circles", label: "Join by invite code", method: "POST", auth: true,
      path: "/api/v1/circles/join",
      body: ~s({\n  "invite_code": "<invite_code>"\n})},
    %{group: "Circles", label: "My circles", method: "GET", auth: true,
      path: "/api/v1/circles/mine", body: ""},
    %{group: "Circles", label: "Discover circles", method: "GET", auth: true,
      path: "/api/v1/circles/discover", body: ""},
    %{group: "Circles", label: "Show circle", method: "GET", auth: true,
      path: "/api/v1/circles/<circle_id>", body: ""},
    %{group: "Circles", label: "Circle members", method: "GET", auth: true,
      path: "/api/v1/circles/<circle_id>/members", body: ""},
    %{group: "Circles", label: "Pending join requests", method: "GET", auth: true,
      path: "/api/v1/circles/<circle_id>/pending", body: ""},
    %{group: "Circles", label: "Approve member", method: "POST", auth: true,
      path: "/api/v1/circles/<circle_id>/approve",
      body: ~s({\n  "member_did": "<member_did>"\n})},
    %{group: "Circles", label: "Deny member", method: "POST", auth: true,
      path: "/api/v1/circles/<circle_id>/deny",
      body: ~s({\n  "member_did": "<member_did>"\n})},
    %{group: "Circles", label: "Add member from contact", method: "POST", auth: true,
      path: "/api/v1/circles/<circle_id>/members/from-contact",
      body: ~s({\n  "contact_id": "<contact_id>"\n})},
    %{group: "Circles", label: "Remove member", method: "DELETE", auth: true,
      path: "/api/v1/circles/<circle_id>/members/<member_did>", body: ""},
    %{group: "Circles", label: "Mute member", method: "POST", auth: true,
      path: "/api/v1/circles/<circle_id>/members/<member_did>/mute", body: ""},
    %{group: "Circles", label: "Send message", method: "POST", auth: true,
      path: "/api/v1/circles/<circle_id>/messages",
      body: ~s({\n  "raw_json": {\n    "type": "Note",\n    "content": "hello circle"\n  }\n})},
    %{group: "Circles", label: "Delete message", method: "DELETE", auth: true,
      path: "/api/v1/circles/<circle_id>/messages/<message_id>", body: ""},
    %{group: "Circles", label: "Pin message", method: "POST", auth: true,
      path: "/api/v1/circles/<circle_id>/messages/<message_id>/pin", body: ""},
    %{group: "Circles", label: "Unpin message", method: "DELETE", auth: true,
      path: "/api/v1/circles/<circle_id>/messages/<message_id>/pin", body: ""},
    %{group: "Circles", label: "List pins", method: "GET", auth: true,
      path: "/api/v1/circles/<circle_id>/pins", body: ""},
    %{group: "Circles", label: "Leave circle", method: "POST", auth: true,
      path: "/api/v1/circles/<circle_id>/leave", body: ""},
    %{group: "Circles", label: "Transfer ownership", method: "POST", auth: true,
      path: "/api/v1/circles/<circle_id>/transfer-ownership",
      body: ~s({\n  "new_owner_did": "<new_owner_did>"\n})},
    %{group: "Circles", label: "Follow circle", method: "POST", auth: true,
      path: "/api/v1/circles/<circle_id>/follow", body: ""},
    %{group: "Circles", label: "Delete circle", method: "DELETE", auth: true,
      path: "/api/v1/circles/<circle_id>", body: ""},

    # -- Contacts / People ----------------------------------------------------
    %{group: "Contacts/People", label: "Lookup by nickname", method: "GET", auth: true,
      path: "/api/v1/contacts/lookup?nickname=<nickname>", body: ""},
    %{group: "Contacts/People", label: "Create contact", method: "POST", auth: true,
      path: "/api/v1/contacts",
      body: ~s({\n  "did": "<contact_did>",\n  "nickname": "<nickname>"\n})},
    %{group: "Contacts/People", label: "List contacts", method: "GET", auth: true,
      path: "/api/v1/contacts", body: ""},
    %{group: "Contacts/People", label: "Contact types", method: "GET", auth: true,
      path: "/api/v1/contacts/types", body: ""},
    %{group: "Contacts/People", label: "Classify contact", method: "POST", auth: true,
      path: "/api/v1/contacts/classify",
      body: ~s({\n  "contact_id": "<contact_id>",\n  "contact_type_id": "<type_id>"\n})},
    %{group: "Contacts/People", label: "Follow suggestions", method: "GET", auth: true,
      path: "/api/v1/contacts/suggestions", body: ""},
    %{group: "Contacts/People", label: "Approve suggestion", method: "POST", auth: true,
      path: "/api/v1/contacts/suggestions/<suggestion_id>/approve", body: ""},
    %{group: "Contacts/People", label: "Dismiss suggestion", method: "POST", auth: true,
      path: "/api/v1/contacts/suggestions/<suggestion_id>/dismiss", body: ""},
    %{group: "Contacts/People", label: "Follow a person", method: "POST", auth: true,
      path: "/api/v1/people/<did>/follow", body: ""},
    %{group: "Contacts/People", label: "Approve follower", method: "POST", auth: true,
      path: "/api/v1/people/<did>/approve", body: ""},
    %{group: "Contacts/People", label: "Deny follower", method: "POST", auth: true,
      path: "/api/v1/people/<did>/deny", body: ""},
    %{group: "Contacts/People", label: "Pending followers", method: "GET", auth: true,
      path: "/api/v1/people/pending", body: ""},

    # -- File sync -------------------------------------------------------------
    %{group: "File sync", label: "Upload blob", method: "POST", auth: true,
      path: "/api/v1/files/sync/blob",
      body: ~s({\n  "space": "core",\n  "content_base64": "<base64 bytes>"\n})},
    %{group: "File sync", label: "Sync record", method: "POST", auth: true,
      path: "/api/v1/files/sync/record",
      body: ~s({\n  "space": "core",\n  "record": {}\n})},
    %{group: "File sync", label: "List remote files", method: "GET", auth: true,
      path: "/api/v1/files/sync/list", body: ""},
    %{group: "File sync", label: "List CAS metadata", method: "GET", auth: true,
      path: "/api/v1/files/sync/cas-meta", body: ""},
    %{group: "File sync", label: "Download blob", method: "GET", auth: true,
      path: "/api/v1/files/sync/blob/<hash>", body: ""},
    %{group: "File sync", label: "List pending syncs", method: "GET", auth: true,
      path: "/api/v1/files/sync/pending", body: ""},
    %{group: "File sync", label: "Mark synced", method: "POST", auth: true,
      path: "/api/v1/files/sync/mark-synced",
      body: ~s({\n  "file_id": "<file_id>",\n  "space": "core"\n})},

    # -- Social sync -------------------------------------------------------------
    %{group: "Social sync", label: "Sync activity", method: "POST", auth: true,
      path: "/api/v1/social/sync/activity",
      body: ~s({\n  "id": "<activity_id>",\n  "user_type": "core",\n  "type": "Note",\n  "content": "hello"\n})},
    %{group: "Social sync", label: "List inbox", method: "GET", auth: true,
      path: "/api/v1/social/sync/inbox", body: ""},
    %{group: "Social sync", label: "List outbox", method: "GET", auth: true,
      path: "/api/v1/social/sync/outbox", body: ""},
    %{group: "Social sync", label: "View activity", method: "GET", auth: true,
      path: "/api/v1/social/sync/view/<activity_id>", body: ""},
    %{group: "Social sync", label: "Save to vault", method: "POST", auth: true,
      path: "/api/v1/social/sync/save",
      body: ~s({\n  "activity_id": "<activity_id>"\n})},
    %{group: "Social sync", label: "Delete activity", method: "DELETE", auth: true,
      path: "/api/v1/social/sync/<activity_id>", body: ""}
  ]

  @groups @presets |> Enum.map(& &1.group) |> Enum.uniq()

  # ── Mount ──────────────────────────────────────────────────────────────

  def mount(_params, _session, socket) do
    first = List.first(@presets)

    {:ok,
     assign(socket,
       base_url: "http://localhost:4000",
       token: "",
       method: first.method,
       path: first.path,
       body: first.body,
       response: nil,
       sending: false,
       groups: @groups,
       presets: @presets
     )}
  end

  # ── Events ─────────────────────────────────────────────────────────────

  def handle_event("load_preset", %{"idx" => idx}, socket) do
    preset = Enum.at(@presets, String.to_integer(idx))

    {:noreply,
     assign(socket, method: preset.method, path: preset.path, body: preset.body, response: nil)}
  end

  def handle_event("form_change", params, socket) do
    {:noreply,
     assign(socket,
       base_url: params["base_url"] || socket.assigns.base_url,
       token: params["token"] || socket.assigns.token,
       method: params["method"] || socket.assigns.method,
       path: params["path"] || socket.assigns.path,
       body: params["body"] || socket.assigns.body
     )}
  end

  def handle_event("send_request", _params, socket) do
    %{base_url: base_url, method: method, path: path, body: body, token: token} = socket.assigns

    case do_request(base_url, method, path, body, token) do
      {:ok, %{status: status, body: resp_body, ms: ms} = resp} ->
        new_token = maybe_extract_token(resp_body) || token

        {:noreply,
         assign(socket,
           response: %{status: status, body: pretty(resp_body), ms: ms, error: nil},
           token: new_token
         )}

      {:error, reason} ->
        {:noreply, assign(socket, response: %{status: nil, body: nil, ms: nil, error: reason})}
    end
  end

  # ── HTTP ───────────────────────────────────────────────────────────────

  defp do_request(base_url, method, path, body, token) do
    {:ok, _} = Application.ensure_all_started(:inets)

    url = String.to_charlist(base_url <> path)
    method_atom = method |> String.downcase() |> String.to_atom()

    headers =
      [{~c"accept", ~c"application/json"}] ++
        if token && token != "" do
          [{~c"authorization", String.to_charlist("Bearer " <> token)}]
        else
          []
        end

    start_ms = System.monotonic_time(:millisecond)

    result =
      if method_atom in [:post, :put, :patch] do
        :httpc.request(method_atom, {url, headers, ~c"application/json", body || ""}, [], [])
      else
        :httpc.request(method_atom, {url, headers}, [], [])
      end

    ms = System.monotonic_time(:millisecond) - start_ms

    case result do
      {:ok, {{_httpver, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, %{status: status, body: List.to_string(resp_body), ms: ms}}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp maybe_extract_token(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"access_token" => token}} -> token
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp maybe_extract_token(_), do: nil

  defp pretty(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      _ -> body
    end
  end

  defp pretty(body), do: inspect(body)

  # ── Render ─────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <div style="display: flex; height: 100vh;">
      <div style="width: 260px; overflow-y: auto; border-right: 1px solid #262932; padding: 12px;">
        <h3 style="margin-top: 0;">PRZMA API Console</h3>
        <div style="font-size: 12px; opacity: 0.6; margin-bottom: 12px;">
          {length(@presets)} presets · {Enum.count(@presets, & &1.auth)} need a token
        </div>
        <div :for={group <- @groups}>
          <div style="font-size: 11px; text-transform: uppercase; opacity: 0.5; margin: 14px 0 6px;">
            {group}
          </div>
          <div :for={{preset, idx} <- Enum.with_index(@presets)} :if={preset.group == group}>
            <button
              phx-click="load_preset"
              phx-value-idx={idx}
              style={"display:flex; justify-content:space-between; width:100%; text-align:left; margin-bottom:4px; padding:6px 8px; border-radius:6px; border:1px solid #262932; background:#171a21; color:#e6e6e6; " <>
                if(@path == preset.path and @method == preset.method, do: "border-color:#4f8cff;", else: "")}
            >
              <span>{preset.label}</span>
              <span style="opacity:0.5; font-size:11px;">{preset.method}</span>
            </button>
          </div>
        </div>
      </div>

      <div style="flex: 1; padding: 16px; overflow-y: auto;">
        <form phx-change="form_change" phx-submit="send_request">
          <div style="display:flex; gap:8px; margin-bottom:8px;">
            <input type="text" name="base_url" value={@base_url} style="width: 260px;" />
            <input
              type="password"
              name="token"
              value={@token}
              placeholder="Bearer token (auto-filled after login)"
              style="flex: 1;"
            />
          </div>

          <div style="display:flex; gap:8px; margin-bottom:8px;">
            <select name="method" style="width: 110px;">
              <option :for={m <- ~w(GET POST PUT PATCH DELETE)} value={m} selected={m == @method}>
                {m}
              </option>
            </select>
            <input type="text" name="path" value={@path} style="flex: 1;" />
            <button
              type="submit"
              style="padding: 8px 20px; border-radius:6px; border:none; background:#4f8cff; color:white; font-weight:600;"
            >
              Send
            </button>
          </div>

          <textarea
            name="body"
            rows="10"
            style="width: 100%; resize: vertical;"
            disabled={@method in ["GET", "DELETE"]}
          >{@body}</textarea>
        </form>

        <div style="margin-top: 16px;">
          <div :if={@response == nil} style="opacity: 0.5;">
            Response will show here.
          </div>
          <div :if={@response && @response.error} style="color: #ff6b6b;">
            Request failed: {@response.error}
            <div style="opacity:0.6; font-size:12px; margin-top:4px;">
              Is the API running on {@base_url}?
            </div>
          </div>
          <div :if={@response && @response.error == nil}>
            <div style="margin-bottom: 8px;">
              <span style={"font-weight:700; " <> if(@response.status < 300, do: "color:#4fd18b;", else: "color:#ff9f4f;")}>
                {@response.status}
              </span>
              <span style="opacity:0.5; margin-left: 8px;">{@response.ms}ms</span>
            </div>
            <pre style="background:#1a1d24; border:1px solid #33363f; border-radius:6px; padding:12px; white-space:pre-wrap; word-break:break-all;">{@response.body}</pre>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
