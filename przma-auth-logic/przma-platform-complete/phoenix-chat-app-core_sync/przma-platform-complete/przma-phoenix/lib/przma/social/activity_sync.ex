defmodule PRZMA.Social.ActivitySync do
  alias PRZMA.PzDb.NIF
  require Logger

  @public "#Public"

  defp vault_base, do: Application.get_env(:przma, :vault_base_path, "s3://perkeep")
  defp dir_for(did), do: "#{vault_base()}/#{sanitize(did)}/social"
  defp sanitize(did), do: did |> String.replace(":", "_") |> String.replace(".", "_")

  def publish(%{"did" => did} = params) do
    with {:ok, version} <- upsert(did, "outbox", row(params, did, "delivered")) do
      Enum.each(List.wrap(params["to"]), &deliver(&1, params))
      {:ok, %{outbox_version: version}}
    end
  end

  defp deliver(@public, _params), do: :ok
  defp deliver("did:" <> _ = recipient_did, params) do
    case upsert(recipient_did, "inbox", row(params, recipient_did, "delivered")) do
      {:ok, _} -> Logger.info("[ActivitySync] delivered id=#{params["id"]} to=#{recipient_did}")
      {:error, reason} -> Logger.warning("[ActivitySync] delivery failed to=#{recipient_did} reason=#{inspect(reason)}")
    end
  end
  defp deliver(_other, _params), do: :ok

  def list_inbox(did, since \\ nil) do
    with {:ok, rows} <- read_table(did, "inbox") do
      visible = Enum.reject(rows, &(&1["status"] == "deleted"))
      {:ok, filter_since(visible, since)}
    end
  end

  def list_outbox(did, since \\ nil) do
    with {:ok, rows} <- read_table(did, "outbox") do
      visible = Enum.reject(rows, &(&1["status"] == "deleted"))
      {:ok, filter_since(visible, since)}
    end
  end

  # `box` defaults to "outbox" so the existing single-arg call sites
  # (e.g. SocialSyncController.delete_activity/2, the caller's own DM feed)
  # keep working unchanged. Pass "inbox" to delete a recipient's copy.
  def delete_activity(did, activity_id, box \\ "outbox") do
    with {:ok, rows} <- read_table(did, box),
        row when not is_nil(row) <- Enum.find(rows, &(to_string(&1["id"]) == to_string(activity_id))) do
      updated = Map.merge(row, %{"status" => "deleted", "deleted_at" => System.os_time(:microsecond)})
      upsert(did, box, updated)
    else
      nil -> {:error, :not_found}
    end
  end

  def get_outbox_row(did, activity_id) do
    with {:ok, rows} <- read_table(did, "outbox") do
      case Enum.find(rows, &(to_string(&1["id"]) == to_string(activity_id) and &1["status"] != "deleted")) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  def get_inbox_row(did, activity_id) do
    with {:ok, rows} <- read_table(did, "inbox") do
      match = Enum.find(rows, fn r ->
        to_string(r["id"]) == to_string(activity_id) or
        to_string(r[:id]) == to_string(activity_id)
      end)
      case match do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  def mark_saved(did, activity_id, saved_file_id) do
    with {:ok, row} <- get_inbox_row(did, activity_id) do
      updated = Map.merge(row, %{"status" => "saved", "saved_file_id" => saved_file_id})
      upsert(did, "inbox", updated)
    end
  end

  defp read_table(did, box) do
    case NIF.pzdb_read_many(dir_for(did), box, "", 500, 0) do
      {:ok, json} -> {:ok, decode(json)}
      json when is_binary(json) -> {:ok, decode(json)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(json) when is_binary(json), do: decode(Jason.decode!(json))
  defp decode(%{"records" => records}) when is_list(records), do: records
  defp decode(list) when is_list(list), do: list
  defp decode(_), do: []

  defp filter_since(rows, nil), do: rows
  defp filter_since(rows, since), do: Enum.filter(rows, fn r -> (r["created_at"] || 0) > since end)

  defp row(params, owner_did, status) do
  enriched_raw =
    enrich_raw_json(
      params["raw_json"] || "{}",
      params["object_cas"],
      params["actor"] || params["did"]
    )

  %{
    "id"            => params["id"],
    "owner_did"     => owner_did,
    "actor"         => params["actor"] || params["did"],
    "activity_type" => params["activity_type"],
    "space"         => params["space"] || "core",
    "object_id"     => params["object_id"],
    "object_cas"    => params["object_cas"],
    "object_name"   => params["object_name"],
    "to_json"       => Jason.encode!(params["to"] || []),
    "raw_json"      => enriched_raw,
    "status"        => status,
    "created_at"    => params["created_at"] || params["created_at_micros"] || System.os_time(:microsecond),
    "saved_file_id" => nil,
    "user_type"     => params["user_type"]
  }
  end
 defp enrich_raw_json(raw_json, nil, _actor), do: raw_json
 defp enrich_raw_json(raw_json, cas, actor) when is_binary(cas) do
  hash     = String.trim_leading(cas, "cas:")
  base_url = Application.get_env(:przma, :base_url, "http://172.235.18.126:4201")
  url      = "#{base_url}/api/v1/files/sync/blob/#{hash}?owner=#{actor}"

  case Jason.decode(raw_json) do
    {:ok, decoded} ->
      enriched =
        case decoded do
          %{"object" => obj} when is_map(obj) ->
            put_in(decoded, ["object", "url"], url)
          _ ->
            decoded
        end
      Jason.encode!(enriched)
    _ ->
      raw_json
  end
end 

  defp upsert(did, box, row) do
    case NIF.pzdb_upsert(dir_for(did), box, Jason.encode!(row), Jason.encode!(["id"])) do
      {:ok, json} -> {:ok, json |> Jason.decode!() |> Map.get("version")}
      json when is_binary(json) -> {:ok, json |> Jason.decode!() |> Map.get("version")}
      {:error, reason} -> {:error, reason}
    end
  end
end