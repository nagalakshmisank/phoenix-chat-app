defmodule ChatApiWeb.TypingController do
  use ChatApiWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Phoenix.PubSub
  alias OpenApiSpex.Schema

  tags ["5. Typing"]

  operation :notify,
    summary: "Broadcast typing indicator to a room",
    description: "Call this when user is typing. All others in the room will see 'karthiga is typing...'",
    parameters: [
      id: [in: :path, type: :string, required: true,
           description: "Room ID — lobby | tamil | gaming"]
    ],
    request_body: {"Typing", "application/json", %Schema{
      type: :object,
      properties: %{
        username: %Schema{type: :string, example: "karthiga",
                          description: "Use if no session"}
      }
    }},
    responses: %{
      200 => {"Broadcast sent", "application/json", %Schema{
        type: :object,
        properties: %{ok: %Schema{type: :boolean}}
      }},
      422 => {"Error", "application/json", %Schema{type: :object}}
    }

  def notify(conn, params) do
    room_id  = params["id"]
    username =
      get_session(conn, :username) ||
      Map.get(params, "username") ||
      "anon"

    if is_nil(room_id) or String.trim(room_id) == "" do
      conn |> put_status(422) |> json(%{error: "room_id missing"})
    else
      PubSub.broadcast(ChatApi.PubSub, "room:#{room_id}", {:typing, username})
      json(conn, %{ok: true})
    end
  end
end
