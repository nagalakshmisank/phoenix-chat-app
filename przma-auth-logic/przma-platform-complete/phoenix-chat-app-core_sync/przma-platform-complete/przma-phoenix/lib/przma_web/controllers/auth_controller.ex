defmodule PRZMAWeb.AuthController do
  use PRZMAWeb, :controller

  alias PRZMA.Auth
  alias PRZMA.Auth.Session
  require Logger

  # POST /api/v1/account/register
  def register(conn, params) do
    case Auth.register(params) do
      {:ok, %{did: did, nickname: nickname, email: email}} ->
        conn
        |> put_status(200)
        |> json(%{
          message: "Registration successful. Check #{email} for your 6-digit code.",
          did: did,
          nickname: nickname,
          next_step: "POST /api/v1/account/verify_email with {nickname, code}"
        })

      {:error, :nickname_taken} ->
        conn |> put_status(409) |> json(%{error: "nickname_taken"})

      {:error, :invalid_nickname} ->
        conn |> put_status(400) |> json(%{error: "nickname must be 1-30 characters"})

      {:error, :invalid_password} ->
        conn |> put_status(400) |> json(%{error: "password must be at least 6 characters"})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  # POST /api/v1/account/verify_email   { "nickname": "...", "code": "123456" }
  def verify_email(conn, %{"nickname" => nickname, "code" => code}) do
    case Auth.verify_email(nickname, code) do
      {:ok, :verified} ->
        json(conn, %{ok: true, message: "Email verified. You can now log in.", next_step: "POST /api/v1/oauth/token"})

      {:error, :max_attempts} ->
        conn |> put_status(429) |> json(%{error: "Too many attempts. Request a new code via /resend_otp."})

      {:error, :expired} ->
        conn |> put_status(400) |> json(%{error: "Code expired. Use /resend_otp."})

      {:error, :invalid} ->
        conn |> put_status(400) |> json(%{error: "Invalid code."})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "User not found"})
    end
  end

  def verify_email(conn, _), do: conn |> put_status(400) |> json(%{error: "nickname and code are required"})

  # POST /api/v1/account/resend_otp   { "nickname": "..." }
  def resend_otp(conn, %{"nickname" => nickname}) do
    case Auth.resend_otp(nickname) do
      {:ok, :sent} ->
        json(conn, %{ok: true, message: "New code sent."})

      {:error, :rate_limited} ->
        conn |> put_status(429) |> json(%{error: "Please wait before requesting another code."})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def resend_otp(conn, _), do: conn |> put_status(400) |> json(%{error: "nickname is required"})

  # POST /api/v1/account/forgot_password   { "nickname": "...", "email": "..." }
  def forgot_password(conn, %{"nickname" => nickname, "email" => email}) do
    {:ok, :sent} = Auth.request_password_reset(nickname, email)

    conn
    |> put_status(200)
    |> json(%{ok: true, message: "If that account exists, a reset code has been sent.", note: "Link expires in 15 minutes."})
  end

  def forgot_password(conn, _), do: conn |> put_status(400) |> json(%{error: "nickname and email are required"})

  # POST /api/v1/account/reset_password   { "nickname", "token", "password", "password_confirmation" }
  def reset_password(conn, params) do
    nickname = params["nickname"]
    token = params["token"]
    password = params["password"]
    confirmation = params["password_confirmation"]

    cond do
      is_nil(nickname) or is_nil(token) or is_nil(password) ->
        conn |> put_status(400) |> json(%{error: "nickname, token, and password are required"})

      String.length(password) < 6 ->
        conn |> put_status(400) |> json(%{error: "Password must be at least 6 characters"})

      password != confirmation ->
        conn |> put_status(400) |> json(%{error: "Passwords do not match"})

      true ->
        case Auth.reset_password(nickname, token, password) do
          {:ok, _did} ->
            json(conn, %{ok: true, message: "Password reset. You can now log in.", next_step: "POST /api/v1/oauth/token"})

          {:error, :max_attempts} ->
            conn |> put_status(429) |> json(%{error: "Too many attempts. Request a new reset link."})

          {:error, :expired} ->
            conn |> put_status(400) |> json(%{error: "Reset link expired."})

          {:error, :invalid} ->
            conn |> put_status(400) |> json(%{error: "Invalid reset link."})

          {:error, :not_found} ->
            conn |> put_status(404) |> json(%{error: "No password reset was requested for this account."})
        end
    end
  end

  # POST /api/v1/oauth/token   { "grant_type": "password", "username": "...", "password": "..." }
  def login(conn, %{"grant_type" => "password"} = params) do
    conn_info = Session.conn_info(conn)

    case Auth.login(params["username"], params["password"], conn_info) do
      {:ok, %{token: token, did: did, nickname: nickname, is_verified: verified, expires_in: expires_in}} ->
        json(conn, %{
          access_token: token,
          token_type: "Bearer",
          expires_in: expires_in,
          did: did,
          me: nickname,
          is_verified: verified
        })

      {:error, :invalid_credentials} ->
        conn |> put_status(401) |> json(%{error: "Invalid nickname or password"})

      {:error, :account_disabled} ->
        conn |> put_status(403) |> json(%{error: "Account is disabled"})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end

  def login(conn, _), do: conn |> put_status(400) |> json(%{error: "unsupported_grant_type"})

  # GET /api/v1/accounts/verify_credentials  (requires :require_did_auth)
  def verify_credentials(conn, _params) do
    did = conn.assigns[:did]

    case Auth.get_account(did) do
      {:ok, account} -> json(conn, account)
      {:error, :invalid_credentials} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # DELETE /oauth/token  — logout current session   { "session_id": "..." }  (optional)
  def logout(conn, params) do
    did = conn.assigns[:did]

    case params["session_id"] do
      nil -> :ok # stateless token — nothing to revoke server-side without a session id
      session_id -> Session.revoke(did, session_id)
    end

    json(conn, %{message: "Logged out"})
  end

  # GET /api/v1/sessions
  def list_sessions(conn, _params) do
    did = conn.assigns[:did]

    case Session.list_active(did) do
      {:ok, sessions} -> json(conn, %{sessions: sessions})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # DELETE /api/v1/sessions/:id
  def revoke_session(conn, %{"id" => session_id}) do
    did = conn.assigns[:did]

    case Session.revoke(did, session_id) do
      {:ok, _} -> json(conn, %{message: "Session revoked"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Session not found"})
    end
  end

  # DELETE /api/v1/sessions  (logout everywhere)
  def revoke_all_sessions(conn, _params) do
    did = conn.assigns[:did]
    :ok = Session.revoke_all(did)
    json(conn, %{message: "Logged out from all devices"})
  end
end