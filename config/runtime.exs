import Config

if System.get_env("PHX_SERVER") do
  config :chat_api, ChatApiWeb.Endpoint, server: true
end

config :chat_api, ChatApiWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]
