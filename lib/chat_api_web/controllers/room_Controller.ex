defmodule ChatApiWeb.RoomController do
  use ChatApiWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  @default_rooms [
    %{id: "lobby",  name: "Lobby",  emoji: "🏠"},
    %{id: "tamil",  name: "Tamil",  emoji: "🗣️"},
    %{id: "gaming", name: "Gaming", emoji: "🎮"}
  ]
  @max_members 5

  tags ["3. Rooms"]

  # ── SWAGGER SPECS ────────────────────────────────────────────

  operation :index,
    summary: "List all rooms with member counts",
    responses: %{
      200 => {"Room list", "application/json", %Schema{
        type: :object,
        properties: %{
          rooms: %Schema{type: :array, items: %Schema{type: :object}}
        }
      }}
    }

  operation :create,
    summary: "Create a new chat room",
    request_body: {"Room", "application/json", %Schema{
      type: :object,
      required: [:name],
      properties: %{
        name:  %Schema{type: :string, example: "general"},
        emoji: %Schema{type: :string, example: "💬"}
      }
    }},
    responses: %{
      200 => {"Created", "application/json", %Schema{type: :object}},
      422 => {"Error",   "application/json", %Schema{type: :object}}
    }

  operation :show,
    summary: "Get room details + who is online",
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Room details", "application/json", %Schema{type: :object}}
    }

  operation :members,
    summary: "Get online members in a room",
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Members", "application/json", %Schema{type: :object}}
    }

  operation :status,
    summary: "Check room status — full or available (audience check)",
    description: "If is_full: true → join as audience. If false → join as member.",
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Status", "application/json", %Schema{
        type: :object,
        properties: %{
          room:    %Schema{type: :string},
          count:   %Schema{type: :integer},
          max:     %Schema{type: :integer},
          is_full: %Schema{type: :boolean},
          mode:    %Schema{type: :string, description: "member | audience"}
        }
      }}
    }

  operation :join,
    summary: "Join room — returns member or audience mode",
    description: "Room full → audience (read only). Room available → member (can send).",
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    request_body: {"Join", "application/json", %Schema{
      type: :object,
      required: [:username],
      properties: %{
        username: %Schema{type: :string, example: "karthiga"}
      }
    }},
    responses: %{
      200 => {"Joined", "application/json", %Schema{
        type: :object,
        properties: %{
          ok:          %Schema{type: :boolean},
          mode:        %Schema{type: :string, example: "member",
                               description: "member | audience"},
          room:        %Schema{type: :string},
          is_audience: %Schema{type: :boolean},
          message:     %Schema{type: :string}
        }
      }},
      422 => {"Error", "application/json", %Schema{type: :object}}
    }

  operation :leave,
    summary: "Leave a room — removes from online members list",
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    request_body: {"Leave", "application/json", %Schema{
      type: :object,
      required: [:username],
      properties: %{
        username: %Schema{type: :string, example: "karthiga"}
      }
    }},
    responses: %{
      200 => {"Left", "application/json", %Schema{
        type: :object,
        properties: %{
          ok:       %Schema{type: :boolean},
          username: %Schema{type: :string},
          room:     %Schema{type: :string}
        }
      }}
    }

  # ── ACTIONS ──────────────────────────────────────────────────

  def index(conn, _params) do
    dynamic_rooms =
      :ets.tab2list(:chat_rooms)
      |> Enum.map(fn {_id, room} -> room end)

    all_rooms =
      (@default_rooms ++ dynamic_rooms)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn room ->
        members = get_room_members(room.id)
        count   = length(members)
        Map.merge(room, %{
          member_count: count,
          max:          @max_members,
          is_full:      count >= @max_members
        })
      end)

    json(conn, %{rooms: all_rooms})
  end

  def create(conn, params) do
    name  = Map.get(params, "name", "") |> String.trim()
    emoji = Map.get(params, "emoji", "💬")

    if name == "" do
      conn |> put_status(422) |> json(%{error: "Room name required"})
    else
      id   = name |> String.downcase() |> String.replace(" ", "-")
      room = %{id: id, name: name, emoji: emoji}
      :ets.insert(:chat_rooms, {id, room})
      json(conn, %{ok: true, room: room})
    end
  end

  def show(conn, %{"id" => id}) do
    members = get_room_members(id)
    count   = length(members)

    json(conn, %{
      id:      id,
      members: members,
      count:   count,
      max:     @max_members,
      is_full: count >= @max_members
    })
  end

  def members(conn, %{"id" => id}) do
    members = get_room_members(id)
    json(conn, %{
      room:    id,
      members: members,
      count:   length(members)
    })
  end

  def status(conn, %{"id" => id}) do
    count   = get_room_members(id) |> length()
    is_full = count >= @max_members

    json(conn, %{
      room:    id,
      count:   count,
      max:     @max_members,
      is_full: is_full,
      mode:    if(is_full, do: "audience", else: "member")
    })
  end

  def join(conn, params) do
    id       = params["id"]
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    members = get_room_members(id)
    count   = length(members)

    if count < @max_members do
      # Member — ETS-ல add பண்ணு
      add_member(id, username)

      # Room-ல எல்லாருக்கும் broadcast — someone joined
      PubSub.broadcast(ChatApi.PubSub, "room:#{id}", {:user_joined, username})

      json(conn, %{
        ok:          true,
        mode:        "member",
        is_audience: false,
        room:        id,
        message:     "#{username} joined as member"
      })
    else
      # Audience — ETS-ல add பண்ணாம (read only)
      json(conn, %{
        ok:          true,
        mode:        "audience",
        is_audience: true,
        room:        id,
        message:     "Room full (#{count}/#{@max_members}) — joined as audience (read only)"
      })
    end
  end

  def leave(conn, params) do
    id       = params["id"]
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    # ETS-இல இருந்து remove பண்ணு
    remove_member(id, username)

    # Room-ல எல்லாருக்கும் broadcast
    PubSub.broadcast(ChatApi.PubSub, "room:#{id}", {:user_left, username})

    json(conn, %{ok: true, username: username, room: id})
  end

  # ── PRIVATE HELPERS ──────────────────────────────────────────

  # Room-ல இருக்கற members list ETS-இல இருந்து எடுக்கறோம்
  defp get_room_members(room_id) do
    key = "members:#{room_id}"
    case :ets.lookup(:chat_rooms, key) do
      [{^key, members}] -> members
      []                -> []
    end
  end

  # Member add பண்றோம் — duplicate இல்லாம
  defp add_member(room_id, username) do
    key     = "members:#{room_id}"
    members = get_room_members(room_id)
    updated = Enum.uniq([username | members])
    :ets.insert(:chat_rooms, {key, updated})
  end

  # Member remove பண்றோம்
  defp remove_member(room_id, username) do
    key     = "members:#{room_id}"
    members = get_room_members(room_id)
    updated = Enum.reject(members, & &1 == username)
    :ets.insert(:chat_rooms, {key, updated})
  end
end
