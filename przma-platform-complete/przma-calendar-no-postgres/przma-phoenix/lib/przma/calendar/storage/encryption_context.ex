# lib/przma/calendar/storage/encryption_context.ex
#
# Client-side encryption context for calendar data.
# Wraps the Rust encryption NIFs with key management and context routing.
# Every vault write passes through here before reaching Lance/S3.

defmodule PRZMA.Calendar.Storage.EncryptionContext do
  alias PRZMA.Calendar.NIF
  require Logger

  # ── KEY MANAGEMENT ───────────────────────────────────────────────────────

  @doc """
  Load the master key for a DID from secure key storage.
  Returns hex-encoded 32-byte master key.

  Key sources by deployment mode:
  - Cloud SaaS:  env var PRZMA_MASTER_KEY_{DID_HASH}
  - BYOS:        same env var (key never leaves user's env)
  - Local:       ~/.config/przma/keys/{did_hash}.key file
  - Own Domain:  /etc/przma/keys/{did_hash}.key file
  """
  def load_master_key(did) do
    did_hash = :crypto.hash(:sha256, did) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    env_key  = "PRZMA_MASTER_KEY_#{String.upcase(did_hash)}"

    cond do
      key = System.get_env(env_key) ->
        {:ok, key}

      PRZMA.Deployment.Mode.local?() ->
        load_key_from_file(did_hash)

      true ->
        {:error, :master_key_not_configured}
    end
  end

  @doc "Derive the key path string for a namespace (used in EncryptedBlob metadata)"
  def key_path(did, namespace) do
    case load_master_key(did) do
      {:ok, master_key} ->
        NIF.derive_namespace_key(master_key, did, namespace)
      {:error, _} ->
        {:error, :no_master_key}
    end
  end

  @doc "Derive the key path for a circle namespace"
  def circle_key_path(did, circle_did, namespace) do
    case load_master_key(did) do
      {:ok, master_key} ->
        NIF.derive_circle_key(master_key, did, circle_did, namespace)
      {:error, _} ->
        {:error, :no_master_key}
    end
  end

  # ── ENCRYPTION ──────────────────────────────────────────────────────────

  @doc """
  Encrypt plaintext binary before storage.
  Returns {:ok, envelope_json} or {:error, reason}.
  """
  def encrypt(did, namespace, plaintext, aad \\ "") when is_binary(plaintext) do
    case load_master_key(did) do
      {:ok, master_key} ->
        NIF.encrypt_blob(master_key, did, namespace, plaintext, aad)
      {:error, _} ->
        # Encryption not configured — return plaintext (dev mode warning)
        Logger.warning("Encryption not configured for DID, storing plaintext", did: did)
        {:ok, Jason.encode!(%{"plaintext" => Base.encode64(plaintext), "encrypted" => false})}
    end
  end

  @doc """
  Decrypt an encrypted envelope back to plaintext.
  Returns {:ok, plaintext} or {:error, reason}.
  """
  def decrypt(did, namespace, envelope_json) when is_binary(envelope_json) do
    # Check if this is encrypted or plaintext fallback
    case Jason.decode(envelope_json) do
      {:ok, %{"encrypted" => false, "plaintext" => b64}} ->
        {:ok, Base.decode64!(b64)}

      {:ok, _} ->
        # Real encrypted blob
        case load_master_key(did) do
          {:ok, master_key} ->
            NIF.decrypt_blob(master_key, did, namespace, envelope_json)
          {:error, _} ->
            {:error, :no_master_key}
        end

      _ ->
        {:error, :invalid_envelope}
    end
  end

  # ── ENCRYPTION-AWARE CAS ─────────────────────────────────────────────────

  @doc """
  Store bytes in CAS with client-side encryption.
  Returns {:ok, content_hash} — hash of plaintext (stable CAS ID).
  """
  def encrypted_cas_put(did, namespace, plaintext) do
    base_path = Application.get_env(:przma, [:vault, :base_path], "/var/przma/vaults")

    case encrypt(did, namespace, plaintext) do
      {:ok, envelope_json} ->
        NIF.cas_put(base_path, did, envelope_json)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Retrieve and decrypt bytes from CAS"
  def encrypted_cas_get(did, namespace, hash) do
    base_path = Application.get_env(:przma, [:vault, :base_path], "/var/przma/vaults")

    with {:ok, envelope_json} <- NIF.cas_get(base_path, did, hash),
         {:ok, plaintext}     <- decrypt(did, namespace, envelope_json) do
      {:ok, plaintext}
    end
  end

  # ── KEY FILE MANAGEMENT ──────────────────────────────────────────────────

  @doc """
  Generate and save a new master key for a DID (initial setup).
  Returns {:ok, master_key_hex}.
  """
  def generate_and_save_master_key(did) do
    did_hash = :crypto.hash(:sha256, did) |> Base.encode16(case: :lower) |> String.slice(0, 16)
    key      = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    case save_key_to_file(did_hash, key) do
      :ok ->
        Logger.info("New master key generated for DID", did: did)
        {:ok, key}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Check if encryption is configured for a DID"
  def encryption_available?(did) do
    case load_master_key(did) do
      {:ok, _}    -> true
      {:error, _} -> false
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp key_file_path(did_hash) do
    base = if PRZMA.Deployment.Mode.own_domain?() do
      "/etc/przma/keys"
    else
      Path.join(System.get_env("HOME", "/root"), ".config/przma/keys")
    end
    Path.join(base, "#{did_hash}.key")
  end

  defp load_key_from_file(did_hash) do
    path = key_file_path(did_hash)
    case File.read(path) do
      {:ok, key}       -> {:ok, String.trim(key)}
      {:error, :enoent} -> {:error, :no_key_file}
      {:error, reason}  -> {:error, reason}
    end
  end

  defp save_key_to_file(did_hash, key_hex) do
    path = key_file_path(did_hash)
    File.mkdir_p!(Path.dirname(path))
    case File.write(path, key_hex, [:exclusive]) do
      :ok ->
        File.chmod!(path, 0o600)  # owner-read-only
        :ok
      {:error, :eexist} ->
        {:error, :key_already_exists}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
