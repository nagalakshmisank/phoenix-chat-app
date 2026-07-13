defmodule PRZMAWeb.CircleController do
  use PRZMAWeb, :controller
  alias PRZMA.Social.{CircleSync, CirclePermissions, ActivitySync}
  require Logger
  @max_message_length 2000

  def create(conn, params) do
    did  = conn.assigns[:did]
    name = params["name"] || "Untitled Circle"
    opts = Map.take(params, ["join_approval_required", "max_members"])

    case CircleSync.create_circle(did, name, opts) do
      {:ok, circle}    -> json(conn, circle)
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def join(conn, %{"invite_code" => code}) do
    did = conn.assigns[:did]
    case CircleSync.join_circle(did, code) do
      {:ok, result} -> json(conn, result)
      {:error, :invite_not_found} -> conn |> put_status(404) |> json(%{error: "invite_not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def approve(conn, %{"circle_id" => circle_id, "member_did" => member_did}) do
    did = conn.assigns[:did]
    with {:ok, circle} <- CircleSync.get_circle_for(did, circle_id),
         {:ok, role}   <- CircleSync.get_role(circle["owner_did"], circle_id, did),
         true          <- CirclePermissions.can?("add_member", role),
         {:ok, updated} <- CircleSync.approve_member(circle["owner_did"], circle_id, member_did) do
      json(conn, updated)
    else
      false -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def deny(conn, %{"circle_id" => circle_id, "member_did" => member_did}) do
    did = conn.assigns[:did]
    with {:ok, circle} <- CircleSync.get_circle_for(did, circle_id),
         {:ok, role}   <- CircleSync.get_role(circle["owner_did"], circle_id, did),
         true          <- CirclePermissions.can?("add_member", role),
         {:ok, _}      <- CircleSync.deny_member(circle["owner_did"], circle_id, member_did) do
      json(conn, %{status: "denied"})
    else
      false -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def remove_member(conn, %{"circle_id" => circle_id, "member_did" => target_did}) do
    did = conn.assigns[:did]
    with {:ok, circle}      <- CircleSync.get_circle_for(did, circle_id),
         {:ok, actor_row}   <- CircleSync.get_member(circle["owner_did"], circle_id, did),
         {:ok, target_row}  <- CircleSync.get_member(circle["owner_did"], circle_id, target_did),
         true               <- CirclePermissions.can_remove?(actor_row["role"], target_row["role"]),
         {:ok, _}           <- CircleSync.remove_member(circle["owner_did"], circle_id, target_did) do
      json(conn, %{status: "removed"})
    else
      false -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def mine(conn, _params) do
    did = conn.assigns[:did]
    case CircleSync.list_my_circles(did) do
      {:ok, rows} -> json(conn, %{circles: rows, count: length(rows)})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def members(conn, %{"circle_id" => circle_id}) do
    did = conn.assigns[:did]
    with {:ok, circle} <- CircleSync.get_circle_for(did, circle_id),
         {:ok, rows}   <- CircleSync.list_members(circle["owner_did"], circle_id) do
      json(conn, %{members: rows, count: length(rows)})
    else
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def send_message(conn, %{"circle_id" => circle_id, "raw_json" => raw_json} = params) do
    did = conn.assigns[:did]
    with :ok            <- validate_length(raw_json),
         {:ok, circle}   <- CircleSync.get_circle_for(did, circle_id),
         owner_did       = circle["owner_did"],
         {:ok, role}     <- CircleSync.get_role(owner_did, circle_id, did),
         true            <- CirclePermissions.can?("send_message", role),
         {:ok, to_list}  <- CircleSync.expand_recipients(owner_did, circle_id) do
      activity = %{
        "id" => params["id"] || "msg_#{circle_id}_#{System.os_time(:microsecond)}",
        "did" => did, "actor" => did, "activity_type" => "Message",
        "space" => "circle:#{circle_id}", "to" => to_list, "raw_json" => raw_json,
        "object_cas" => params["object_cas"], "object_name" => params["object_name"]
      }
      case ActivitySync.publish(activity) do
        {:ok, %{outbox_version: v}} ->
          PRZMAWeb.Endpoint.broadcast("circle:#{circle_id}", "new_message", activity)
          json(conn, %{id: activity["id"], status: "synced", version: v})
        {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    else
      {:error, :too_long} -> conn |> put_status(400) |> json(%{error: "message_too_long", max: @max_message_length})
      false -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "circle_not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end
  def show(conn, %{"circle_id" => circle_id}) do
    did = conn.assigns[:did]
    case CircleSync.get_circle_for(did, circle_id) do
      {:ok, circle} -> json(conn, circle)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def delete(conn, %{"circle_id" => circle_id}) do
    did = conn.assigns[:did]
    with {:ok, circle} <- CircleSync.get_circle_for(did, circle_id),
        owner_did = circle["owner_did"],
        {:ok, role} <- CircleSync.get_role(owner_did, circle_id, did),
        true <- CirclePermissions.can?("delete_circle", role),
        {:ok, _} <- CircleSync.delete_circle(owner_did, circle_id) do
      json(conn, %{status: "deleted"})
    else
      false -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def delete_message(conn, %{"circle_id" => _circle_id, "message_id" => message_id}) do
    did = conn.assigns[:did]
    case ActivitySync.delete_activity(did, message_id) do
      {:ok, _} -> json(conn, %{status: "deleted"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def pin_message(conn, %{"circle_id" => circle_id, "message_id" => message_id}) do
    did = conn.assigns[:did]
    with {:ok, circle} <- CircleSync.get_circle_for(did, circle_id),
        owner_did = circle["owner_did"],
        {:ok, role} <- CircleSync.get_role(owner_did, circle_id, did),
        true <- CirclePermissions.can?("delete_edit_others_messages", role),
        {:ok, _} <- CircleSync.pin_message(owner_did, circle_id, message_id, did) do
      json(conn, %{status: "pinned"})
    else
      false -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def unpin_message(conn, %{"circle_id" => circle_id, "message_id" => message_id}) do
    did = conn.assigns[:did]
    with {:ok, circle} <- CircleSync.get_circle_for(did, circle_id),
        owner_did = circle["owner_did"],
        {:ok, role} <- CircleSync.get_role(owner_did, circle_id, did),
        true <- CirclePermissions.can?("delete_edit_others_messages", role),
        {:ok, _} <- CircleSync.unpin_message(owner_did, circle_id, message_id) do
      json(conn, %{status: "unpinned"})
    else
      false -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def mute_member(conn, %{"circle_id" => circle_id, "member_did" => member_did}) do
    did = conn.assigns[:did]
    with {:ok, circle} <- CircleSync.get_circle_for(did, circle_id),
        owner_did = circle["owner_did"],
        {:ok, role} <- CircleSync.get_role(owner_did, circle_id, did),
        true <- CirclePermissions.can?("remove_member", role),
        {:ok, updated} <- CircleSync.update_role(owner_did, circle_id, member_did, "restricted") do
      json(conn, updated)
    else
      false -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def pending(conn, %{"circle_id" => circle_id}) do
    did = conn.assigns[:did]
    with {:ok, circle}   <- CircleSync.get_circle_for(did, circle_id),
        owner_did       = circle["owner_did"],
        {:ok, role}     <- CircleSync.get_role(owner_did, circle_id, did),
        true            <- CirclePermissions.can?("add_member", role),
        {:ok, rows}     <- CircleSync.list_pending(owner_did, circle_id) do
      json(conn, %{pending: rows, count: length(rows)})
    else
      false -> conn |> put_status(403) |> json(%{error: "forbidden"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  defp validate_length(raw_json) do
    case Jason.decode(raw_json) do
      {:ok, %{"content" => content}} when is_binary(content) ->
        if String.length(content) <= @max_message_length, do: :ok, else: {:error, :too_long}
      _ ->
        :ok
    end
  end
end