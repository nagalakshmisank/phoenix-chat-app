defmodule PRZMA.Auth.PasswordReset do
  @moduledoc """
  Forgot-password flow. Reset token stored as a Pbkdf2 hash on the auth row,
  15-minute expiry, single use. Same full-row read/merge/write pattern as OTP.
  """

  alias PRZMA.PzDb
  alias PRZMA.Auth.Mailer
  require Logger

  @token_expiry_micros 900 * 1_000_000
  @max_attempts 3
  @resend_cooldown_micros 60 * 1_000_000

  defp auth_uri(did), do: "pzdb://#{did}/auth/core/auth/#{did}"

  @doc "Called by PRZMA.Auth with an already-resolved DID + row (email confirmed by caller)."
  def request_reset_for_did(did, row) do
    with :ok <- check_cooldown(row) do
      {plain, hashed} = pair()
      now = System.os_time(:microsecond)

      merged =
        Map.merge(row, %{
          "reset_token" => hashed,
          "reset_token_expires_at" => now + @token_expiry_micros,
          "reset_token_attempts" => 0,
          "updated_at" => now
        })

      with {:ok, _} <- PzDb.write(auth_uri(did), merged) do
        Mailer.deliver_reset(row["email"], row["nickname"], plain, did)
        {:ok, :sent}
      end
    else
      {:error, :rate_limited} -> {:ok, :sent}
    end
  end
  

  @doc """
  Verify token + set new password.
  Returns {:ok, did} | {:error, :invalid | :expired | :max_attempts | :not_found}
  """
  def reset_password(did, token, new_password) do
    with {:ok, row} <- read_row(did) do
      cond do
        is_nil(row["reset_token"]) ->
          {:error, :not_found}

        (row["reset_token_attempts"] || 0) >= @max_attempts ->
          invalidate(did, row)
          {:error, :max_attempts}

        expired?(row["reset_token_expires_at"]) ->
          invalidate(did, row)
          {:error, :expired}

        not Pbkdf2.verify_pass(token, row["reset_token"]) ->
          increment_attempts(did, row)
          {:error, :invalid}

        true ->
          apply_new_password(did, row, new_password)
      end
    end
  end

  # ── private ──────────────────────────────────────────────────────────────

  

  defp read_row(did) do
    case PzDb.query(auth_uri(did), filter: "id = '#{esc(did)}'", limit: 1) do
      {:ok, %{"records" => [row | _]}} -> {:ok, row}
      {:ok, %{"records" => []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pair do
    plain = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    {plain, Pbkdf2.hash_pwd_salt(plain)}
  end

  defp check_cooldown(%{"reset_token_expires_at" => nil}), do: :ok

  defp check_cooldown(%{"reset_token_expires_at" => expires_at}) do
    sent_at = expires_at - @token_expiry_micros
    since = System.os_time(:microsecond) - sent_at
    if since < @resend_cooldown_micros, do: {:error, :rate_limited}, else: :ok
  end

  defp expired?(nil), do: true
  defp expired?(expires_at), do: System.os_time(:microsecond) > expires_at

  defp increment_attempts(did, row) do
    now = System.os_time(:microsecond)

    merged =
      Map.merge(row, %{
        "reset_token_attempts" => (row["reset_token_attempts"] || 0) + 1,
        "updated_at" => now
      })

    PzDb.write(auth_uri(did), merged)
  end

  defp invalidate(did, row) do
    now = System.os_time(:microsecond)

    merged =
      Map.merge(row, %{
        "reset_token" => nil,
        "reset_token_expires_at" => nil,
        "reset_token_attempts" => 0,
        "updated_at" => now
      })

    PzDb.write(auth_uri(did), merged)
  end

  defp apply_new_password(did, row, new_password) do
    now = System.os_time(:microsecond)

    merged =
      Map.merge(row, %{
        "password_hash" => Pbkdf2.hash_pwd_salt(new_password),
        "reset_token" => nil,
        "reset_token_expires_at" => nil,
        "reset_token_attempts" => 0,
        "updated_at" => now
      })

    with {:ok, _} <- PzDb.write(auth_uri(did), merged) do
      {:ok, did}
    end
  end

  defp esc(s), do: String.replace(s, "'", "''")
end