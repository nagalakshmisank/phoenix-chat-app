defmodule ChatApiWeb.ApiSpec do
  alias OpenApiSpex.{Info, OpenApi, Paths, Server}
  alias ChatApiWeb.Router
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [%Server{url: "http://localhost:4000"}],
      info: %Info{
        title:   "Chat App API",
        version: "1.0.0",
        description: "Phoenix Chat API — rooms, messages, presence, typing"
      },
      paths: Paths.from_router(Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
