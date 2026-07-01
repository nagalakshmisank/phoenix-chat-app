# lib/przma/calendar/federation/activitypub.ex
#
# ActivityPub federation context for PRZMA Calendar.
# Handles publishing events to Commons, delivering activities to followers,
# and processing inbound ActivityPub objects.

defmodule PRZMA.Calendar.Federation.ActivityPub do
  alias PRZMA.Calendar.{NIF, Events}
  alias PRZMA.Calendar.Federation.{HTTPSignature, DIDResolver}
  alias PRZMAWeb.Endpoint

  require Logger

  @base_path    Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")
  @instance_url Application.compile_env(:przma, [:instance, :url], "https://przma.ai")

  # ── PUBLISH EVENT TO COMMONS ─────────────────────────────────────────────

  @doc """
  Publish a calendar event to Commons via ActivityPub.
  1. Build AP Event object
  2. Sign with DID key
  3. Store AP object ID in event record
  4. Deliver Create activity to followers
  5. Broadcast publish confirmation
  """
  def publish_event(did, event_id, space \\ "core") do
    with {:ok, event}    <- Events.get(did, event_id, space),
         :ok              <- verify_visibility_public(event),
         {:ok, ap_object} <- build_event_object(event),
         {:ok, event}    <- store_ap_object_id(did, event, ap_object["id"]),
         :ok              <- deliver_to_followers(did, "create", ap_object) do

      # Move event to commons Lance namespace
      commons_event = Map.merge(event, %{
        "space"      => "commons",
        "visibility" => "public",
        "updated_at" => System.os_time(:microsecond),
      })
      NIF.create_event(@base_path, did, Jason.encode!(commons_event))

      broadcast_published(did, event_id, ap_object["id"])
      Logger.info("Event published to Commons", event_id: event_id, ap_id: ap_object["id"])
      {:ok, %{ap_object_id: ap_object["id"], url: ap_object["url"]}}
    end
  end

  @doc """
  Unpublish a previously published event.
  Sends Delete/Tombstone activity to followers.
  """
  def unpublish_event(did, event_id) do
    with {:ok, event} <- Events.get(did, event_id, "commons"),
         ap_id        <- event["ap_object_id"],
         true         <- not is_nil(ap_id) do

      actor_url   = actor_url(did)
      activity_id = generate_activity_id()
      delete_act  = Jason.encode!(build_delete_activity(ap_id, actor_url, activity_id))

      deliver_to_followers(did, "delete", Jason.decode!(delete_act))
      Events.cancel(did, event_id, "commons")

      Logger.info("Event unpublished from Commons", event_id: event_id)
      {:ok, :unpublished}
    else
      false -> {:error, :not_published}
      error -> error
    end
  end

  # ── INBOX PROCESSING ─────────────────────────────────────────────────────

  @doc """
  Process an inbound ActivityPub activity.
  Called by the inbox controller after HTTP Signature verification.
  """
  def process_inbound(did, activity) do
    activity_type = activity["type"]
    Logger.debug("Processing inbound AP activity",
      type: activity_type, target_did: did)

    case activity_type do
      "Create" -> handle_create(did, activity)
      "Update" -> handle_update(did, activity)
      "Delete" -> handle_delete(did, activity)
      "Accept" -> handle_rsvp_accept(did, activity)
      "Reject" -> handle_rsvp_reject(did, activity)
      "Invite" -> handle_invite(did, activity)
      "Follow" -> handle_follow(did, activity)
      "Undo"   -> handle_undo(did, activity)
      other    ->
        Logger.debug("Unhandled AP activity type", type: other)
        :ok
    end
  end

  # ── FOLLOWER DELIVERY ─────────────────────────────────────────────────────

  @doc "Deliver an activity to all followers of a DID"
  def deliver_to_followers(did, activity_type, activity_object) do
    actor_url   = actor_url(did)
    activity_id = generate_activity_id()

    activity = case activity_type do
      "create" -> build_create_activity(activity_object, actor_url, activity_id)
      "update" -> build_update_activity(activity_object, actor_url, activity_id)
      "delete" -> activity_object  # already a delete activity
      _        -> activity_object
    end

    activity_json = Jason.encode!(activity)

    # Get followers and deliver asynchronously via Oban
    followers = PRZMA.Repo.list_followers(did)
    Enum.each(followers, fn follower ->
      PRZMA.Calendar.Jobs.APDelivery.enqueue(
        follower.inbox_url,
        activity_json,
        did
      )
    end)

    {:ok, length(followers)}
  end

  @doc "Deliver an activity to a specific inbox URL"
  def deliver_to_inbox(inbox_url, activity_json, sender_did) do
    with {:ok, private_key} <- HTTPSignature.load_private_key(sender_did),
         key_id              <- HTTPSignature.key_id_for_did(sender_did, @instance_url),
         {:ok, headers}     <- HTTPSignature.sign_request(
           "POST", inbox_url, activity_json, key_id, private_key) do

      case HTTPoison.post(inbox_url, activity_json, Map.to_list(headers),
            recv_timeout: 10_000, follow_redirect: true) do
        {:ok, %{status_code: code}} when code in 200..299 ->
          {:ok, :delivered}

        {:ok, %{status_code: code}} ->
          {:error, {:http_error, code}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── ACTOR DOCUMENT ───────────────────────────────────────────────────────

  def actor_document(did) do
    display_name = did |> String.split(":") |> List.last()
    public_key   = get_public_key_pem(did)

    case NIF.build_ap_actor(@base_path, did, display_name, @instance_url, public_key) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      error       -> error
    end
  end

  # ── OUTBOX ───────────────────────────────────────────────────────────────

  def outbox(did, page \\ 1) do
    events = Events.list(did, space: "commons", limit: 20) |> elem(1) |> Kernel.||([])
    items  = Enum.map(events, fn e -> build_event_object_sync(e) end)

    {:ok, %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type"     => "OrderedCollectionPage",
      "id"       => "#{actor_url(did)}/outbox?page=#{page}",
      "partOf"   => "#{actor_url(did)}/outbox",
      "items"    => items,
      "totalItems" => length(items),
    }}
  end

  # ── PRIVATE: INBOUND HANDLERS ────────────────────────────────────────────

  defp handle_create(target_did, activity) do
    with {:ok, parsed} <- parse_ap_activity(activity) do
      if parsed["object_type"] == "Event" do
        # Import event from external AP actor
        import_external_event(target_did, parsed)
      else
        :ok
      end
    end
  end

  defp handle_update(_target_did, _activity), do: :ok  # Phase 4: update commons events

  defp handle_delete(target_did, activity) do
    # Mark the AP-originated event as cancelled
    ap_id = get_in(activity, ["object", "id"]) || activity["object"]
    if ap_id do
      Logger.info("Received Delete for AP object", ap_id: ap_id)
    end
    :ok
  end

  defp handle_rsvp_accept(organiser_did, activity) do
    actor_url  = activity["actor"]
    event_url  = activity["object"]
    attendee_did = url_to_did(actor_url)

    Endpoint.broadcast("calendar:personal:#{organiser_did}", "event:rsvp", %{
      event_url:    event_url,
      attendee_did: attendee_did,
      status:       "accepted",
    })
    :ok
  end

  defp handle_rsvp_reject(organiser_did, activity) do
    actor_url    = activity["actor"]
    event_url    = activity["object"]
    attendee_did = url_to_did(actor_url)

    Endpoint.broadcast("calendar:personal:#{organiser_did}", "event:rsvp", %{
      event_url:    event_url,
      attendee_did: attendee_did,
      status:       "declined",
    })
    :ok
  end

  defp handle_invite(target_did, activity) do
    obj = activity["object"] || %{}
    Endpoint.broadcast("calendar:personal:#{target_did}", "invite:received", %{
      from_did:  url_to_did(activity["actor"] || ""),
      title:     obj["name"] || "Event Invite",
      start_at:  obj["startTime"],
      ap_id:     obj["id"],
    })
    :ok
  end

  defp handle_follow(target_did, activity) do
    follower_did = url_to_did(activity["actor"] || "")
    PRZMA.Repo.insert_follower(%{
      did:        target_did,
      follower_did: follower_did,
      inbox_url:  get_inbox_url(follower_did),
    })
    Logger.info("New follower", target: target_did, follower: follower_did)
    :ok
  end

  defp handle_undo(_target_did, _activity), do: :ok

  # ── PRIVATE: HELPERS ─────────────────────────────────────────────────────

  defp build_event_object(event) do
    case NIF.build_ap_event_object(@base_path, Jason.encode!(event), @instance_url) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      error       -> error
    end
  end

  defp build_event_object_sync(event) do
    case build_event_object(event) do
      {:ok, obj} -> obj
      _          -> %{}
    end
  end

  defp build_create_activity(obj, actor_url, activity_id) do
    case NIF.build_ap_create_activity(
           @base_path,
           Jason.encode!(obj),
           actor_url,
           activity_id) do
      {:ok, json} -> Jason.decode!(json)
      _           -> %{}
    end
  end

  defp build_update_activity(obj, actor_url, activity_id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type"     => "Update",
      "id"       => activity_id,
      "actor"    => actor_url,
      "object"   => obj,
    }
  end

  defp build_delete_activity(object_url, actor_url, activity_id) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "type"     => "Delete",
      "id"       => activity_id,
      "actor"    => actor_url,
      "object"   => %{"type" => "Tombstone", "id" => object_url},
    }
  end

  defp parse_ap_activity(activity) do
    case NIF.parse_ap_activity(@base_path, Jason.encode!(activity)) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      error       -> error
    end
  end

  defp import_external_event(target_did, parsed) do
    if parsed["start_time"] do
      {:ok, start_dt, _} = DateTime.from_iso8601(parsed["start_time"])
      {:ok, end_dt, _}   = DateTime.from_iso8601(parsed["end_time"] || parsed["start_time"])

      event_attrs = %{
        "title"        => parsed["title"],
        "description"  => parsed["content"],
        "category"     => "EVENT",
        "start_at"     => DateTime.to_unix(start_dt, :microsecond),
        "end_at"       => DateTime.to_unix(end_dt, :microsecond),
        "space"        => "core",
        "visibility"   => "private",
        "ap_object_id" => parsed["ap_id"],
        "external_id"  => parsed["ap_id"],
      }
      Events.create(target_did, event_attrs)
    else
      :ok
    end
  end

  defp store_ap_object_id(did, event, ap_id) do
    updated = Map.put(event, "ap_object_id", ap_id)
    Events.update(did, event["id"], event["space"], %{"ap_object_id" => ap_id})
    {:ok, updated}
  end

  defp verify_visibility_public(%{"visibility" => "public"}),  do: :ok
  defp verify_visibility_public(_), do: {:error, :event_not_public}

  defp broadcast_published(did, event_id, ap_id) do
    Endpoint.broadcast("calendar:personal:#{did}", "event:published", %{
      event_id: event_id,
      ap_id:    ap_id,
    })
  end

  defp actor_url(did) do
    encoded = URI.encode(did)
    "#{@instance_url}/ap/actor/#{encoded}"
  end

  defp generate_activity_id do
    token = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "#{@instance_url}/ap/activities/#{token}"
  end

  defp get_public_key_pem(_did) do
    # Phase 5: load from encrypted key store
    "-----BEGIN PUBLIC KEY-----\nPHASE5_PLACEHOLDER\n-----END PUBLIC KEY-----"
  end

  defp url_to_did(url) do
    # Attempt to extract DID from AP actor URL
    case Regex.run(~r|/ap/actor/(.+)$|, url) do
      [_, encoded] -> URI.decode(encoded)
      _            -> url
    end
  end

  defp get_inbox_url(did) do
    encoded = URI.encode(did)
    "#{@instance_url}/ap/inbox/#{encoded}"
  end
end
