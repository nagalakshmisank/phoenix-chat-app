defmodule PRZMA.Auth.OTP do
  @moduledoc """
  6-digit email verification code, stored as a Pbkdf2 hash on the same auth
  row (no separate table — matches the reference project's design).

  Every function here follows read-full-row -> merge -> write-full-row,
  because a Lance upsert replaces the whole row, not just the changed keys.
  """

  alias PRZMA.PzDb
  alias PRZMA.Auth.Mailer
  require Logger

  @otp_expiry_micros 600 * 1_000_000
  @max_attempts 3
  @resend_cooldown_micros 60 * 1_000_000

  defp auth_uri(did), do: "pzdb://#{did}/auth/core/auth/#{did}"

  @doc "Generate + store a fresh hashed OTP, email the plaintext. Full-row read/write."
  def generate_and_send(did) do
    with {:ok, row} <- read_row(did),
         :ok <- check_cooldown(row) do
      {plain, hashed} = pair()
      now = System.os_time(:microsecond)

      merged =
        Map.merge(row, %{
          "otp_code" => hashed,
          "otp_expires_at" => now + @otp_expiry_micros,
          "otp_attempts" => 0,
          "updated_at" => now
        })

      with {:ok, _} <- PzDb.write(auth_uri(did), merged) do
        Mailer.deliver_otp(row["email"], row["nickname"], plain)
        {:ok, :sent}
      end
    end
  end

  @doc """
  Verify a submitted code.
  Returns {:ok, :verified} | {:error, :invalid | :expired | :max_attempts | :not_found}
  """
  def verify(did, submitted_code) when is_binary(submitted_code) do
    with {:ok, row} <- read_row(did) do
      cond do
        (row["otp_attempts"] || 0) >= @max_attempts ->
          {:error, :max_attempts}

        is_nil(row["otp_code"]) ->
          {:error, :invalid}

        expired?(row["otp_expires_at"]) ->
          {:error, :expired}

        not Pbkdf2.verify_pass(submitted_code, row["otp_code"]) ->
          increment_attempts(did, row)
          {:error, :invalid}

        true ->
          mark_verified(did, row)
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
    plain =
      :rand.uniform(999_999)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

    {plain, Pbkdf2.hash_pwd_salt(plain)}
  end

  defp check_cooldown(%{"otp_expires_at" => nil}), do: :ok

  defp check_cooldown(%{"otp_expires_at" => expires_at}) do
    sent_at = expires_at - @otp_expiry_micros
    since = System.os_time(:microsecond) - sent_at

    if since < @resend_cooldown_micros, do: {:error, :rate_limited}, else: :ok
  end

  defp expired?(nil), do: true
  defp expired?(expires_at), do: System.os_time(:microsecond) > expires_at

  defp increment_attempts(did, row) do
    now = System.os_time(:microsecond)
    merged = Map.merge(row, %{"otp_attempts" => (row["otp_attempts"] || 0) + 1, "updated_at" => now})
    PzDb.write(auth_uri(did), merged)
  end

  defp mark_verified(did, row) do
    now = System.os_time(:microsecond)

    merged =
      Map.merge(row, %{
        "is_verified" => true,
        "otp_code" => nil,
        "otp_expires_at" => nil,
        "otp_attempts" => 0,
        "updated_at" => now
      })

    with {:ok, _} <- PzDb.write(auth_uri(did), merged) do
      {:ok, :verified}
    end
  end

  defp esc(s), do: String.replace(s, "'", "''")
end