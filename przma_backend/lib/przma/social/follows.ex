defmodule Przma.Social.Follows do
  @moduledoc """
  Following a person. Every follow is active immediately (private
  accounts / approval are not implemented yet).

      follower's database   social:private:following:{target_key}   "I follow X"
      target's database     chat:private:inbox:follow-{follower_key} "X follows me"

  The follower writes their own `following` document; the target's side
  is an inbox item delivered by Przma.Chat.Delivery with a FIXED record
  id (one per follower), so the target's inbox doubles as the follower
  list and an unfollow simply updates the same item.

  Contact suggestions = active followers that are not contacts yet and
  were not dismissed.
  """

  alias Przma.Chat.Delivery
  alias Przma.Notify.Notifications
  alias Przma.Social.{Contacts, Directory, Key, Store}

  @thread "follow"

  def follow(%{did: me}, target_did) do
    with :ok <- check(target_did != me, :cannot_follow_yourself),
         {:ok, target} <- Directory.account(target_did),
         :ok <-
           Store.put(me, "social", "following", Key.did_key(target_did), %{
             "target_did" => target_did,
             "nickname" => target["nickname"],
             "follow_status" => "active",
             "followed_at" => System.os_time(:microsecond)
           }),
         {:ok, %{failed: []}} <- deliver_record(me, target_did, "active") do
      Notifications.send([target_did], me, "Follow", "follow", "#{name(me)} started following you", %{
        "subject_did" => me
      })

      {:ok, %{"target_did" => target_did, "follow_status" => "active"}}
    else
      {:ok, %{failed: _}} -> {:error, :unknown_user}
      err -> err
    end
  end

  def unfollow(%{did: me}, target_did) do
    with {:ok, %{"follow_status" => "active"}} <- Store.get(me, "social", "following", Key.did_key(target_did)),
         :ok <- Store.put(me, "social", "following", Key.did_key(target_did), %{"follow_status" => "removed"}) do
      deliver_record(me, target_did, "removed")
      {:ok, %{"target_did" => target_did, "follow_status" => "removed"}}
    else
      {:ok, _} -> {:error, :not_following}
      {:error, :not_found} -> {:error, :not_following}
      err -> err
    end
  end

  @doc "People the caller follows."
  def following(me) do
    with {:ok, rows} <- Store.list(me, "social", "following", limit: 1000) do
      {:ok, Enum.filter(rows, &(&1["follow_status"] == "active"))}
    end
  end

  @doc "People who follow the caller."
  def followers(me) do
    with {:ok, rows} <- Store.list(me, "chat", "inbox", prefix: Key.thread_prefix(@thread), limit: 1000) do
      {:ok, rows |> Enum.filter(&(&1["follow_status"] == "active")) |> Enum.map(&follower_view/1)}
    end
  end

  def follower(me, follower_did) do
    with {:ok, row} <- Store.get(me, "chat", "inbox", record(follower_did)), do: {:ok, follower_view(row)}
  end

  @doc "Followers the caller could add as contacts."
  def suggestions(me) do
    with {:ok, followers} <- followers(me),
         {:ok, contacts} <- Contacts.list(me) do
      known = MapSet.new(contacts, & &1["contact_did"])

      {:ok, Enum.reject(followers, &(&1["dismissed"] == true or MapSet.member?(known, &1["follower_did"])))}
    end
  end

  def dismiss_suggestion(%{did: me}, follower_did) do
    with {:ok, _} <- Store.get(me, "chat", "inbox", record(follower_did)),
         :ok <- Store.put(me, "chat", "inbox", record(follower_did), %{"dismissed" => true}) do
      {:ok, %{"follower_did" => follower_did, "dismissed" => true}}
    end
  end

  # ── private ──────────────────────────────────────────────────────────

  defp deliver_record(follower, target, follow_status) do
    item = %{
      "msg_id" => Key.message_id(),
      "activity_type" => "Follow",
      "category" => "follow",
      "actor_did" => follower,
      "follow_status" => follow_status,
      "sent_at" => System.os_time(:microsecond)
    }

    Delivery.deliver([target], item, thread: @thread, record: record(follower), count: false)
  end

  defp record(follower_did), do: Key.record(@thread, Key.did_key(follower_did))

  defp follower_view(row) do
    %{
      "follower_did" => row["actor_did"],
      "follow_status" => row["follow_status"],
      "dismissed" => row["dismissed"] == true,
      "followed_at" => row["sent_at"]
    }
  end

  defp name(did), do: Directory.display_name(did)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
