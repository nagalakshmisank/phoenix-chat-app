defmodule ChatApiWeb.TokenController do
  use ChatApiWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias OpenApiSpex.Schema

  tags ["1. Token"]

  operation :create,
    summary: "Get WebSocket connection token",
    description: "Call this first. Returns a token to connect to WebSocket. Frontend team — use this token in WS params.",
    request_body: {"Token request", "application/json", %Schema{
      type: :object,
      required: [:username],
      properties: %{
        username: %Schema{type: :string, example: "karthiga",
                          description: "Your username"}
      }
    }},
    responses: %{
      200 => {"Token issued", "application/json", %Schema{
        type: :object,
        properties: %{
          token:      %Schema{type: :string, example: "a2FydGhpZ2E6MTcxMjM="},
          username:   %Schema{type: :string, example: "karthiga"},
          expires_in: %Schema{type: :integer, example: 3600}
        }
      }}
    }

  def create(conn, params) do
    username = Map.get(params, "username", "anon") |> String.trim()

    if username == "" do
      conn |> put_status(422) |> json(%{error: "Username required"})
    else
      token = Base.encode64("#{username}:#{System.system_time(:second)}")

      conn
      |> put_session(:username, username)
      |> json(%{
        token:      token,
        username:   username,
        expires_in: 3600
      })
    end
  end
end
