defmodule PRZMAWeb.Presence do
  use Phoenix.Presence,
    otp_app: :przma,
    pubsub_server: PRZMA.PubSub
end