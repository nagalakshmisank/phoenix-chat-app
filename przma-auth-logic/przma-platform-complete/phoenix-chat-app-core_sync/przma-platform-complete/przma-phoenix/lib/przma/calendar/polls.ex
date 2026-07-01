# lib/przma/calendar/polls.ex

defmodule PRZMA.Calendar.Polls do
  alias PRZMA.Calendar.{NIF, Events, Circles, Governance}
  alias PRZMA.Identity
  alias PRZMAWeb.Endpoint

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── CREATE ───────────────────────────────────────────────────────────────────

  def create(creator_did, circle_did, attrs) do
    with {:ok, role} <- Identity.get_role(creator_did, circle_did),
         :ok         <- Governance.assert_permitted(role, :create_poll) do

      poll = %{
        "id"               => generate_id(creator_did),
        "circle_did"       => circle_did,
        "created_by"       => creator_did,
        "title"            => attrs["title"] || "Scheduling Poll",
        "description"      => attrs["description"] || "",
        "poll_type"        => attrs["poll_type"] || "date",
        "options"          => build_options(attrs["options"] || []),
        "votes"            => %{},
        "status"           => "open",
        "resolved_option"  => nil,
        "auto_create_event"=> attrs["auto_create_event"] || false,
        "resulting_event_id" => nil,
        "closes_at"        => attrs["closes_at"],
        "created_at"       => now_micros(),
        "updated_at"       => now_micros(),
      }

      # Store in each member's circle namespace
      members = Identity.circle_member_dids(circle_did)
      Enum.each(members, fn did ->
        NIF.create_task(@base_path, did, Jason.encode!(poll))
      end)

      broadcast_poll_created(poll, circle_did)
      {:ok, poll}
    end
  end

  # ── GET ──────────────────────────────────────────────────────────────────────

  def get(poll_id, circle_did, requester_did) do
    with {:ok, _role} <- Identity.get_role(requester_did, circle_did) do
      case PRZMA.Repo.get_poll(poll_id, circle_did) do
        nil  -> {:error, :not_found}
        poll -> {:ok, poll}
      end
    end
  end

  def list(circle_did, requester_did \\ nil) do
    polls = PRZMA.Repo.list_polls(circle_did)
    {:ok, polls}
  end

  # ── VOTE ─────────────────────────────────────────────────────────────────────

  def vote(poll_id, circle_did, voter_did, option_ids) when is_list(option_ids) do
    with {:ok, role} <- Identity.get_role(voter_did, circle_did),
         :ok         <- Governance.assert_permitted(role, :vote),
         {:ok, poll} <- get(poll_id, circle_did, voter_did) do

      if poll["status"] != "open" do
        {:error, :poll_not_open}
      else
        updated = Map.update!(poll, "votes", fn votes ->
          Map.put(votes, voter_did, option_ids)
        end)
        |> Map.put("updated_at", now_micros())

        PRZMA.Repo.update_poll(updated)

        broadcast_poll_vote(poll_id, voter_did, option_ids, circle_did)
        {:ok, updated}
      end
    end
  end

  # ── RESOLVE ──────────────────────────────────────────────────────────────────

  @doc """
  Close a poll and declare the winning option.
  If auto_create_event is true and winning option has a date, creates a circle event.
  """
  def resolve(poll_id, circle_did, winning_option_id, resolved_by_did) do
    with {:ok, role} <- Identity.get_role(resolved_by_did, circle_did),
         :ok         <- Governance.assert_permitted(role, :resolve_poll),
         {:ok, poll} <- get(poll_id, circle_did, resolved_by_did) do

      winning = Enum.find(poll["options"], fn o -> o["id"] == winning_option_id end)

      updated = poll
        |> Map.put("status", "resolved")
        |> Map.put("resolved_option", winning_option_id)
        |> Map.put("updated_at", now_micros())

      PRZMA.Repo.update_poll(updated)

      # Auto-create event if configured and winning option has a date
      resulting_event_id =
        if poll["auto_create_event"] and winning && winning["start_at"] do
          {:ok, event} = create_event_from_poll(poll, winning, resolved_by_did, circle_did)
          event["id"]
        end

      final = Map.put(updated, "resulting_event_id", resulting_event_id)
      PRZMA.Repo.update_poll(final)

      broadcast_poll_resolved(poll_id, winning_option_id, resulting_event_id, circle_did)
      {:ok, final}
    end
  end

  # ── TALLY ────────────────────────────────────────────────────────────────────

  @doc "Count votes per option, sorted by highest count"
  def tally(poll_id, circle_did, requester_did) do
    with {:ok, poll} <- get(poll_id, circle_did, requester_did) do
      counts =
        poll["votes"]
        |> Enum.flat_map(fn {_did, option_ids} -> option_ids end)
        |> Enum.frequencies()

      tally =
        poll["options"]
        |> Enum.map(fn opt ->
            %{
              option_id:    opt["id"],
              label:        opt["label"],
              vote_count:   Map.get(counts, opt["id"], 0),
              voter_count:  Enum.count(poll["votes"], fn {_, ids} -> opt["id"] in ids end),
            }
          end)
        |> Enum.sort_by(& &1.vote_count, :desc)

      {:ok, %{
        poll_id:     poll_id,
        total_votes: map_size(poll["votes"]),
        tally:       tally,
        winner:      poll["resolved_option"],
      }}
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────────

  defp build_options(options) do
    Enum.map(options, fn opt ->
      Map.put_new(opt, "id", generate_id("opt"))
    end)
  end

  defp create_event_from_poll(poll, winning_option, creator_did, circle_did) do
    event_attrs = %{
      "title"       => poll["title"],
      "description" => "Created from scheduling poll: #{poll["title"]}",
      "category"    => "EVENT",
      "start_at"    => winning_option["start_at"],
      "end_at"      => winning_option["end_at"] || (winning_option["start_at"] + 7200_000_000),
      "space"       => "core",
      "visibility"  => "private",
      "location_ref"=> winning_option["location_ref"] || "",
    }

    with {:ok, event} <- Events.create(creator_did, event_attrs) do
      # Share to circle so all members see it
      Circles.share_event(creator_did, event["id"], circle_did)
      {:ok, event}
    end
  end

  defp broadcast_poll_created(poll, circle_did) do
    members = Identity.circle_member_dids(circle_did)
    Enum.each(members, fn did ->
      Endpoint.broadcast("calendar:circle:#{circle_did}:#{did}", "poll:created", %{
        id:            poll["id"],
        title:         poll["title"],
        poll_type:     poll["poll_type"],
        options_count: length(poll["options"]),
        closes_at:     poll["closes_at"],
      })
    end)
  end

  defp broadcast_poll_vote(poll_id, voter_did, option_ids, circle_did) do
    members = Identity.circle_member_dids(circle_did)
    Enum.each(members, fn did ->
      Endpoint.broadcast("calendar:circle:#{circle_did}:#{did}", "poll:vote", %{
        poll_id:    poll_id,
        voter_did:  voter_did,
        option_ids: option_ids,
      })
    end)
  end

  defp broadcast_poll_resolved(poll_id, winning_option, event_id, circle_did) do
    members = Identity.circle_member_dids(circle_did)
    Enum.each(members, fn did ->
      Endpoint.broadcast("calendar:circle:#{circle_did}:#{did}", "poll:resolved", %{
        poll_id:          poll_id,
        winning_option:   winning_option,
        event_created_id: event_id,
      })
    end)
  end

  defp generate_id(prefix) do
    token = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{prefix}-#{token}"
  end

  defp now_micros, do: System.os_time(:microsecond)
end
