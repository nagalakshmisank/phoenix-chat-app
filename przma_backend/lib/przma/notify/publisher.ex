defmodule Przma.Notify.Publisher do
  @moduledoc """
  Pushes live events to connected clients through GraphQL subscriptions:

      notificationReceived        topic "user:<did>"      (one per user)
      circleEvent(circleId: ..)   topic "circle:<id>"     (members of a circle)

  Live push is a convenience on top of the stored data — a failure here
  is logged and never fails the request that caused it.
  """

  require Logger

  def notify(did, item), do: publish(item, notification_received: "user:" <> did)

  def circle_event(circle_id, event, payload \\ %{}) do
    data =
      payload
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"circle_id" => circle_id, "event" => event, "at" => System.os_time(:microsecond)})

    publish(data, circle_event: "circle:" <> circle_id)
  end

  defp publish(payload, topics) do
    Absinthe.Subscription.publish(PRZMAWeb.Endpoint, payload, topics)
    :ok
  rescue
    error ->
      Logger.debug("live publish skipped: #{inspect(error)}")
      :ok
  catch
    _kind, _reason -> :ok
  end
end
