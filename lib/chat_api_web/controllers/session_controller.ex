defmodule ChatApiWeb.SessionController do
  use ChatApiWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias OpenApiSpex.Schema

  @rooms ["lobby", "tamil", "gaming"]

  tags ["2. Session"]

  operation :join,
    summary: "Save username and room in session",
    description: "Save your name and chosen room. Required before joining a room.",
    request_body: {"Join payload", "application/json", %Schema{
      type: :object,
      required: [:username, :room],
      properties: %{
        username: %Schema{type: :string, example: "karthiga"},
        room:     %Schema{type: :string, example: "lobby",
                          description: "lobby | tamil | gaming"}
      }
    }},
    responses: %{
      200 => {"Session saved", "application/json", %Schema{
        type: :object,
        properties: %{
          ok:       %Schema{type: :boolean, example: true},
          username: %Schema{type: :string,  example: "karthiga"},
          room:     %Schema{type: :string,  example: "lobby"}
        }
      }},
      422 => {"Invalid input", "application/json", %Schema{
        type: :object,
        properties: %{error: %Schema{type: :string}}
      }}
    }

  operation :me,
    summary: "Get current session user info",
    description: "Returns who is currently logged in this session.",
    responses: %{
      200 => {"Session info", "application/json", %Schema{
        type: :object,
        properties: %{
          username: %Schema{type: :string, nullable: true, example: "karthiga"},
          room:     %Schema{type: :string, nullable: true, example: "lobby"}
        }
      }}
    }

  def join(conn, params) do
    username = Map.get(params, "username", "") |> String.trim()
    room     = Map.get(params, "room", "")

    cond do
      username == "" ->
        conn |> put_status(422) |> json(%{error: "Username is required"})

      room not in @rooms ->
        conn |> put_status(422) |> json(%{error: "Invalid room. Choose: lobby | tamil | gaming"})

      true ->
        conn
        |> put_session(:username, username)
        |> put_session(:room, room)
        |> json(%{ok: true, username: username, room: room})
    end
  end

  def me(conn, _params) do
    json(conn, %{
      username: get_session(conn, :username),
      room:     get_session(conn, :room)
    })
  end
end
