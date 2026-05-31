# lib/przma/pzdb/notification/storage.ex
#
# Local file storage for large notification payloads and attachments.
#
# Previously used S3/Linode object storage. Now stores everything
# locally under the vault base path.
#
# Local directory layout:
#   {base_path}/notifications_storage/{did}/inbox/{message_id}/payload.json
#   {base_path}/notifications_storage/{did}/outbox/{message_id}/payload.json
#   {base_path}/notifications_storage/{did}/attachments/{message_id}/{filename}
#
# base_path is read from config :przma, [:vault, :base_path]
# (env var: PRZMA_LOCAL_PATH, default: /tmp/przma_vaults)

defmodule PRZMA.PzDb.Notification.Storage do
  @moduledoc """
  Local file storage for large notification payloads and attachments.
  Replaces S3/Linode object storage with local disk storage.
  """

  require Logger

  @base_storage_path Application.compile_env(:pzdb, [:vault, :base_path], "/tmp/przma_vaults")

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  @doc """
  Store a large message payload locally.

  Returns {:ok, file_key} | {:error, reason}
  """
  def put_payload(did, box, message_id, body) when box in [:inbox, :outbox] do
    key      = payload_key(did, box, message_id)
    full_path = full_path(key)
    content  = Jason.encode!(%{body: body, stored_at: DateTime.utc_now() |> DateTime.to_iso8601()})

    case write_file(full_path, content) do
      :ok           -> {:ok, key}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Retrieve a message payload from local storage.

  Returns {:ok, body_string} | {:error, :not_found} | {:error, reason}
  """
  def get_payload(file_key) do
    full_path = full_path(file_key)

    case File.read(full_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"body" => body}} -> {:ok, body}
          _                        -> {:ok, content}
        end
      {:error, :enoent} ->
        {:error, :not_found}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Store an attachment blob locally.

  Returns {:ok, file_key} | {:error, reason}
  """
  def put_attachment(did, message_id, filename, data, _content_type \\ "application/octet-stream") do
    key       = attachment_key(did, message_id, filename)
    full_path = full_path(key)

    case write_file(full_path, data) do
      :ok           -> {:ok, key}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Get the local file path for an attachment.
  Returns {:ok, path} | {:error, reason}
  """
  def attachment_url(file_key, _ttl_seconds \\ 3600) do
    full_path = full_path(file_key)
    if File.exists?(full_path) do
      {:ok, full_path}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Delete all local files for a message (payload + attachments).
  Call when a message is hard-deleted after retention period.
  """
  def delete_message_objects(did, box, message_id) when box in [:inbox, :outbox] do
    key       = payload_key(did, box, message_id)
    full_path = full_path(key)
    File.rm(full_path)

    # Delete attachments directory for this message
    attachment_dir = Path.join([
      @base_storage_path,
      "notifications_storage",
      did,
      "attachments",
      message_id
    ])
    File.rm_rf(attachment_dir)
    :ok
  end

  @doc """
  Check local storage directory is accessible.
  Returns :ok | {:error, reason}
  """
  def health_check do
    storage_root = Path.join(@base_storage_path, "notifications_storage")
    case File.mkdir_p(storage_root) do
      :ok ->
        case File.stat(storage_root) do
          {:ok, %{type: :directory}} -> :ok
          _                          -> {:error, :storage_unavailable}
        end
      {:error, reason} ->
        Logger.warning("Local storage health check failed", reason: reason)
        {:error, reason}
    end
  end

  # ── KEY HELPERS ─────────────────────────────────────────────────────────────

  def payload_key(did, box, message_id) do
    "#{did}/notifications/#{box}/#{message_id}/payload.json"
  end

  def attachment_key(did, message_id, filename) do
    safe_name = Path.basename(filename)
    "#{did}/notifications/attachments/#{message_id}/#{safe_name}"
  end

  # ── PRIVATE ─────────────────────────────────────────────────────────────────

  defp full_path(key) do
    Path.join([@base_storage_path, "notifications_storage", key])
  end

  defp write_file(full_path, content) do
    dir = Path.dirname(full_path)
    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(full_path, content) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Local storage write failed", path: full_path, reason: reason)
        {:error, reason}
    end
  end
end
