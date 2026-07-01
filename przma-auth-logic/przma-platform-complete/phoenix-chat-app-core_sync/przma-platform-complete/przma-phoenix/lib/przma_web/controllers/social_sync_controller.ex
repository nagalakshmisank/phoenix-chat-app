defmodule PRZMAWeb.SocialSyncController do
  use PRZMAWeb, :controller

  alias PRZMA.Social.ActivitySync
  alias PRZMA.Platform.CAS
  alias PRZMA.Platform.ServicesCatalogue, as: SC
  require Logger

  def sync_activity(conn, params) do
    auth_did = conn.assigns[:did]
    with :ok <- verify_did(auth_did, params["did"]),
         :ok <- require_fields(params, ~w(id did actor activity_type space to raw_json)),
         {:ok, %{outbox_version: version}} <- ActivitySync.publish(params) do
      json(conn, %{id: params["id"], status: "synced", version: version})
    else
      {:error, :did_mismatch} -> conn |> put_status(403) |> json(%{error: "did_mismatch"})
      {:error, {:missing_fields, f}} -> conn |> put_status(400) |> json(%{error: "missing: #{Enum.join(f, ", ")}"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def list_inbox(conn, params) do
    did = conn.assigns[:did]
    case ActivitySync.list_inbox(did, parse_since(params["since"])) do
	{:ok, rows} ->
         enriched = Enum.map(rows, &add_object_url(&1, conn))
	 conn
         |> put_resp_content_type("application/activity+json")
         |> json(%{activities: enriched, count: length(enriched)})
      {:error, reason} ->
	 conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def view_activity(conn, %{"activity_id" => activity_id}) do
  did = conn.assigns[:did]
  Logger.info("[view_activity] START did=#{did} activity_id=#{activity_id}")
  
  with {:ok, activity} <- ActivitySync.get_inbox_row(did, activity_id) do
    Logger.info("[view_activity] found activity: #{inspect(activity)}")
    case resolve_pointer(activity) do
      {:ok, {owner_did, hash}} ->
        Logger.info("[view_activity] resolved pointer: owner=#{owner_did} hash=#{hash}")
        case CAS.get(owner_did, SC.cas_uri(hash)) do
          {:ok, bytes} ->
            Logger.info("[view_activity] got blob bytes: #{byte_size(bytes)}")
            conn
            |> put_resp_content_type("application/octet-stream") 
            |> send_resp(200, bytes)
          {:error, reason} ->
            Logger.error("[view_activity] CAS.get FAILED: #{inspect(reason)}")
            conn |> put_status(404) |> json(%{error: "blob_not_found: #{inspect(reason)}"})
        end
      {:error, reason} ->
        Logger.error("[view_activity] resolve_pointer FAILED: #{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  else
    {:error, reason} ->
      Logger.error("[view_activity] get_inbox_row FAILED: #{inspect(reason)}")
      conn |> put_status(404) |> json(%{error: inspect(reason)})
   end
  end


  def save_to_vault(conn, %{"activity_id" => activity_id}) do
  did = conn.assigns[:did]
  Logger.info("[save_to_vault] START did=#{did} activity_id=#{activity_id}")
  
  with {:ok, activity} <- ActivitySync.get_inbox_row(did, activity_id) do
    Logger.info("[save_to_vault] found activity")
    case resolve_pointer(activity) do
      {:ok, {owner_did, hash}} ->
        Logger.info("[save_to_vault] resolved: owner=#{owner_did} hash=#{hash}")
        case CAS.get(owner_did, SC.cas_uri(hash)) do
          {:ok, plaintext} ->
            Logger.info("[save_to_vault] got blob: #{byte_size(plaintext)} bytes")
            case CAS.put(did, plaintext, written_by: "files") do
              {:ok, new_cas_uri} ->
                new_hash = SC.cas_hash(new_cas_uri)
                {:ok, _} = ActivitySync.mark_saved(did, activity_id, new_hash)
                Logger.info("[save_to_vault] saved to Bob's CAS and marked saved")
                json(conn, %{status: "saved", new_hash: new_hash, cas_uri: new_cas_uri})
              {:error, reason} ->
                Logger.error("[save_to_vault] CAS.put FAILED: #{inspect(reason)}")
                conn |> put_status(500) |> json(%{error: inspect(reason)})
            end
          {:error, reason} ->
            Logger.error("[save_to_vault] CAS.get FAILED: #{inspect(reason)}")
            conn |> put_status(500) |> json(%{error: inspect(reason)})
        end
      {:error, reason} ->
        Logger.error("[save_to_vault] resolve_pointer FAILED: #{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  else
    {:error, reason} ->
      Logger.error("[save_to_vault] get_inbox_row FAILED: #{inspect(reason)}")
      conn |> put_status(404) |> json(%{error: inspect(reason)})
  end
end


  defp resolve_pointer(%{"object_cas" => cas, "actor" => owner_did}) when is_binary(cas) do
    {:ok, {owner_did, String.trim_leading(cas, "cas:")}}
  end
  defp resolve_pointer(_), do: {:error, :no_object_cas}

 defp add_object_url(%{"object_cas" => cas, "actor" => actor} = row, conn) when is_binary(cas) do
    hash = String.trim_leading(cas, "cas:")
    Map.put(row, "object_url", "#{base_url(conn)}/api/v1/files/sync/blob/#{hash}?owner=#{actor}")
  end
  defp add_object_url(row, _conn), do: row

  defp base_url(conn) do
    "#{conn.scheme}://#{conn.host}:#{conn.port}"
  end

  defp parse_since(nil), do: nil
  defp parse_since(s) when is_binary(s), do: String.to_integer(s)
  defp parse_since(n) when is_integer(n), do: n

  defp verify_did(nil, _), do: :ok
  defp verify_did(a, r) when a == r, do: :ok
  defp verify_did(_, _), do: {:error, :did_mismatch}

  defp require_fields(params, fields) do
    case Enum.filter(fields, &is_nil(params[&1])) do
      [] -> :ok
      missing -> {:error, {:missing_fields, missing}}
    end
  end
end
