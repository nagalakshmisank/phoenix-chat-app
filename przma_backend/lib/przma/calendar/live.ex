defmodule Przma.Calendar.Live do
  @moduledoc """
  Live push for calendar changes over the GraphQL subscription
  `calendarUpdated(calendarId)` (topic "calendar:<calendar_id>").

  Same rule as Przma.Notify.Publisher: live push is a convenience on top of
  the stored data, so a failure is logged and never fails the write.
  """

  require Logger

  @doc "event: event_created | event_updated | event_cancelled | rsvp_changed | calendar_updated | calendar_shared"
  def publish(calendar_id, event, actor_did, extra \\ %{}) do
    payload =
      Map.merge(extra, %{
        "calendar_id" => calendar_id,
        "event" => event,
        "actor_did" => actor_did,
        "at" => Przma.Calendar.Ids.to_iso(Przma.Calendar.Ids.now_us())
      })

    Absinthe.Subscription.publish(PRZMAWeb.Endpoint, payload, calendar_updated: "calendar:" <> calendar_id)
    :ok
  rescue
    error ->
      Logger.debug("calendar live publish skipped: #{inspect(error)}")
      :ok
  catch
    _kind, _reason -> :ok
  end
end
