defmodule PRZMA.Auth do
  @moduledoc """
  Pure-Lance authentication context. No Postgres, no Ecto, no migrations.

  Storage layout (same did → service → space → table convention as
  files/social):
    pzdb://{did}/auth/core/auth/{did}          — one profile row per DID
    pzdb://{did}/auth/core/sessions/{sess_id}  — one row per login

  DID is *computed*, never looked up: did = "did:przma:" <> nickname.
  Tokens are self-describing (Phoenix.Token) — verifying one is pure
  computation, no Lance read required.
  """

  alias PRZMA.PzDb
  alias PRZMA.Auth.{Token, OTP, PasswordReset, Session}
  require Logger

  # ── DID ──────────────────────────────────────────────────────────────────

  def did_for(nickname) when is_binary(nickname), do: "did:przma:" <> nickname

  defp auth_uri(did), do: "pzdb://#{did}/auth/core/auth/#{did}"

  # ── REGISTER ─────────────────────────────────────────────────────────────

  @doc """
  Register a new account.
  attrs: %{"nickname" => _, "password" => _, "email" => _, "name" => _, "bio" => _}
  Returns {:ok, %{did:, nickname:, email:}} | {:error, reason}
  """
  def register(%{"nickname" => nickname, "password" => password} = attrs) do
    with :ok <- validate(nickname, password),
         did = did_for(nickname),
         {:ok, :available} <- check_available(did) do
      now = System.os_time(:microsecond)

      record = %{
        "id" => did,
        "did" => did,
        "nickname" => nickname,
        "email" => attrs["email"],
        "name" => attrs["name"] || nickname,
        "bio" => attrs["bio"],
        "avatar" => nil,
        "password_hash" => Pbkdf2.hash_pwd_salt(password),
        "is_active" => true,
        "is_admin" => false,
        "is_moderator" => false,
        "is_verified" => false,
        "otp_code" => nil,
        "otp_expires_at" => nil,
        "otp_attempts" => 0,
        "reset_token" => nil,
        "reset_token_expires_at" => nil,
        "reset_token_attempts" => 0,
        "created_at" => now,
        "updated_at" => now
      }

      with :ok <- PzDb.ensure_table(auth_uri(did)),
           {:ok, _} <- PzDb.write(auth_uri(did), record) do
        case OTP.generate_and_send(did) do
          {:ok, :sent} -> :ok
          {:error, reason} -> Logger.warning("[Auth] OTP send failed did=#{did}: #{inspect(reason)}")
        end

        {:ok, %{did: did, nickname: nickname, email: attrs["email"]}}
      end
    end
  end

  def register(_), do: {:error, :missing_fields}

  defp validate(nickname, password) do
    cond do
      not is_binary(nickname) or String.length(nickname) < 1 -> {:error, :invalid_nickname}
      String.length(nickname) > 30 -> {:error, :invalid_nickname}
      not is_binary(password) or String.length(password) < 6 -> {:error, :invalid_password}
      true -> :ok
    end
  end

  defp check_available(did) do
    case PzDb.query(auth_uri(did), filter: "id = '#{esc(did)}'", limit: 1) do
      {:ok, %{"records" => []}} -> {:ok, :available}
      {:ok, %{"records" => [_ | _]}} -> {:error, :nickname_taken}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── EMAIL VERIFICATION (OTP) ─────────────────────────────────────────────

  def verify_email(nickname, code) do
    did = did_for(nickname)
    OTP.verify(did, code)
  end

  def resend_otp(nickname) do
    did = did_for(nickname)
    OTP.generate_and_send(did)
  end

  # ── LOGIN ────────────────────────────────────────────────────────────────

  @doc """
  Full login: verify credentials, issue a signed token, record a session.
  Returns {:ok, %{token:, did:, nickname:, expires_in:}} | {:error, reason}
  """
  def login(nickname, password, conn_info \\ %{}) do
    did = did_for(nickname)

    with {:ok, row} <- fetch_row(did),
         :ok <- check_password(password, row["password_hash"]),
         :ok <- check_active(row["is_active"]) do
      token = Token.sign(did)
      {:ok, _session_id} = Session.create(did, conn_info)

      {:ok,
       %{
         token: token,
         did: did,
         nickname: row["nickname"],
         is_verified: row["is_verified"],
         expires_in: Token.max_age()
       }}
    end
  end

  defp fetch_row(did) do
    case PzDb.query(auth_uri(did), filter: "id = '#{esc(did)}'", limit: 1) do
      {:ok, %{"records" => [row | _]}} -> {:ok, row}
      {:ok, %{"records" => []}} -> {:error, :invalid_credentials}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_password(password, hash) when is_binary(hash) do
    if Pbkdf2.verify_pass(password, hash), do: :ok, else: {:error, :invalid_credentials}
  end

  defp check_password(_password, _hash) do
    Pbkdf2.no_user_verify()
    {:error, :invalid_credentials}
  end

  defp check_active(true), do: :ok
  defp check_active(_), do: {:error, :account_disabled}

  # ── TOKEN VERIFY (used by the DIDAuth plug) ─────────────────────────────

  @doc "Pure computation — no Lance read. Returns {:ok, did} | {:error, reason}."
  def verify_token(token), do: Token.verify(token)

  # ── PASSWORD RESET ───────────────────────────────────────────────────────

  @doc """
  Since pure Lance has no cross-DID email index, the client must supply the
  nickname alongside the email so the DID can be computed directly.
  """
  def request_password_reset(nickname, email) do
    did = did_for(nickname)

    case fetch_row(did) do
      {:ok, row} ->
        if String.downcase(row["email"] || "") == String.downcase(email) do
          PasswordReset.request_reset_for_did(did, row)
        else
          {:ok, :sent} # don't reveal mismatch
        end

      {:error, _} ->
        {:ok, :sent}
    end
  end

  def reset_password(nickname, token, new_password) do
    did = did_for(nickname)
    PasswordReset.reset_password(did, token, new_password)
  end

  # ── ACCOUNT ──────────────────────────────────────────────────────────────

  def get_account(did) do
    case fetch_row(did) do
      {:ok, row} -> {:ok, render_account(row)}
      err -> err
    end
  end

  defp render_account(row) do
    %{
      did: row["did"],
      username: row["nickname"],
      display_name: row["name"] || row["nickname"],
      email: row["email"],
      bio: row["bio"] || "",
      avatar: row["avatar"] || "",
      is_verified: row["is_verified"],
      is_active: row["is_active"],
      is_admin: row["is_admin"],
      is_moderator: row["is_moderator"],
      created_at: row["created_at"]
    }
  end

  defp esc(s), do: String.replace(s, "'", "''")
end