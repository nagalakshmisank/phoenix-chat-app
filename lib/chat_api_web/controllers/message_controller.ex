defmodule ChatApiWeb.MessageController do
  use ChatApiWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  @max_length 280

  tags ["4. Messages"]

  operation :index,
    summary: "Get paginated message history",
    description: "Loads past messages for a room. Use page + per_page for pagination.",
    parameters: [
      id:       [in: :path,  type: :string,  required: true,
                 description: "Room ID — lobby | tamil | gaming"],
      page:     [in: :query, type: :integer, required: false,
                 description: "Page number (default: 1)"],
      per_page: [in: :query, type: :integer, required: false,
                 description: "Messages per page (default: 20)"]
    ],
    responses: %{
      200 => {"Message history", "application/json", %Schema{
        type: :object,
        properties: %{
          room:     %Schema{type: :string},
          page:     %Schema{type: :integer},
          per_page: %Schema{type: :integer},
          total:    %Schema{type: :integer},
          messages: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                user:   %Schema{type: :string},
                body:   %Schema{type: :string},
                tagged: %Schema{type: :string, nullable: true}
              }
            }
          }
        }
      }}
    }

  operation :send_message,
    summary: "Send a message to a room",
    description: "Send public message to room. Use @username in body to send private message.",
    parameters: [
      id: [in: :path, type: :string, required: true,
           description: "Room ID — lobby | tamil | gaming"]
    ],
    request_body: {"Message", "application/json", %Schema{
      type: :object,
      required: [:body],
      properties: %{
        body:     %Schema{type: :string, example: "hello everyone",
                          description: "Max 280 chars. Use @username for private."},
        username: %Schema{type: :string, example: "karthiga",
                          description: "Use if no session"}
      }
    }},
    responses: %{
      200 => {"Sent", "application/json", %Schema{
        type: :object,
        properties: %{
          ok:      %Schema{type: :boolean},
          message: %Schema{
            type: :object,
            properties: %{
              user:   %Schema{type: :string},
              body:   %Schema{type: :string},
              tagged: %Schema{type: :string, nullable: true}
            }
          }
        }
      }},
      422 => {"Error", "application/json", %Schema{
        type: :object,
        properties: %{
          error: %Schema{type: :string},
          max:   %Schema{type: :integer, nullable: true}
        }
      }}
    }

  operation :send_private,
    summary: "Send a private DM to a specific user",
    description: "Direct message — only sender and receiver will see this.",
    request_body: {"Private DM", "application/json", %Schema{
      type: :object,
      required: [:to, :body],
      properties: %{
        to:       %Schema{type: :string, example: "ravi",
                          description: "Target username"},
        body:     %Schema{type: :string, example: "hey only you see this"},
        username: %Schema{type: :string, example: "karthiga",
                          description: "Sender — use if no session"}
      }
    }},
    responses: %{
      200 => {"DM delivered", "application/json", %Schema{
        type: :object,
        properties: %{
          ok:           %Schema{type: :boolean},
          delivered_to: %Schema{type: :string}
        }
      }},
      422 => {"Error", "application/json", %Schema{type: :object}}
    }

  # ── ACTIONS ─────────────────────────────────────────────────

  def index(conn, %{"id" => room_id} = params) do
    page     = Map.get(params, "page",     "1")  |> String.to_integer()
    per_page = Map.get(params, "per_page", "20") |> String.to_integer()

    all_messages =
      :ets.tab2list(:chat_messages)
      |> Enum.filter(fn {_k, room, _msg} -> room == room_id end)
      |> Enum.sort()
      |> Enum.map(fn {_k, _room, msg} -> msg end)

    total    = length(all_messages)
    messages = all_messages
               |> Enum.drop((page - 1) * per_page)
               |> Enum.take(per_page)

    json(conn, %{
      room:     room_id,
      page:     page,
      per_page: per_page,
      total:    total,
      messages: messages
    })
  end

  def send_message(conn, params) do
    body    = Map.get(params, "body", "")
    room_id = params["id"]
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    cond do
      is_nil(room_id) or String.trim(room_id) == "" ->
        conn |> put_status(422) |> json(%{error: "room_id missing"})

      String.trim(body) == "" ->
        conn |> put_status(422) |> json(%{error: "Empty message"})

      String.length(body) > @max_length ->
        conn |> put_status(422) |> json(%{error: "Too long — max #{@max_length} chars", max: @max_length})

      true ->
        tagged = extract_tag(body)
        msg    = %{user: username, body: body, tagged: tagged}

        case tagged do
          nil ->
            # Public — ETS-ல store + room-க்கு broadcast
            :ets.insert(:chat_messages, {
              System.unique_integer([:positive]), room_id, msg
            })
            PubSub.broadcast(ChatApi.PubSub, "room:#{room_id}", {:new_msg, msg})

          target ->
            # Private @tag — ETS-ல store வேண்டாம்
            PubSub.broadcast(ChatApi.PubSub, "private:#{target}", {:new_msg, msg})
            if target != username do
              PubSub.broadcast(ChatApi.PubSub, "private:#{username}", {:new_msg, msg})
            end
        end

        json(conn, %{ok: true, message: msg})
    end
  end

  def send_private(conn, params) do
    target   = Map.get(params, "to",   "")
    body     = Map.get(params, "body", "")
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    cond do
      String.trim(target) == "" ->
        conn |> put_status(422) |> json(%{error: "Target username (to) required"})

      String.trim(body) == "" ->
        conn |> put_status(422) |> json(%{error: "Empty message"})

      String.length(body) > @max_length ->
        conn |> put_status(422) |> json(%{error: "Too long", max: @max_length})

      true ->
        msg = %{user: username, body: body, tagged: target, private: true}
        PubSub.broadcast(ChatApi.PubSub, "private:#{target}", {:new_msg, msg})
        json(conn, %{ok: true, delivered_to: target})
    end
  end

  defp extract_tag(body) do
    case Regex.run(~r/@(\S+)/, body) do
      [_full, name] -> name
      nil           -> nil
    end
  end
end
