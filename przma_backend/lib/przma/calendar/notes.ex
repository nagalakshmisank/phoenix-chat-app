defmodule Przma.Calendar.Notes do
  @moduledoc """
  Two kinds of notes on an event:

    * SHARED notes — the event's "notes" field. Everyone who can see the
      event reads them; editors change them with updateEvent (agenda,
      packing list, meeting minutes).

    * PRIVATE notes — this module. Stored in the CALLER's own database,
      so nobody else can read them, not even the event's owner:

          {me}/calendar/private/private_notes.lance   {event_id}   text
  """

  alias Przma.Calendar.{Events, Ids}
  alias Przma.Social.Store

  @max_length 5_000

  def set(%{did: me}, calendar_id, event_id, text) when is_binary(text) do
    text = String.trim(text)

    with :ok <- if(String.length(text) <= @max_length, do: :ok, else: {:error, :note_too_long}),
         {:ok, _} <- Events.visible(me, calendar_id, event_id),
         :ok <-
           Store.put(me, "calendar", "private_notes", event_id, %{
             "calendar_id" => calendar_id,
             "event_id" => event_id,
             "text" => text,
             "edited_at" => Ids.now_us()
           }) do
      {:ok, text}
    end
  end

  def set(_me, _calendar_id, _event_id, _text), do: {:error, :invalid_note}

  @doc "My private note on one event, or nil."
  def get(did, event_id) do
    case Store.get(did, "calendar", "private_notes", event_id) do
      {:ok, %{"text" => text}} when text != "" -> text
      _ -> nil
    end
  end

  @doc "event_id => text for my most recent 1000 notes (one read for a whole agenda)."
  def map_for(did) do
    case Store.list(did, "calendar", "private_notes", limit: 1000, descending: true) do
      {:ok, rows} -> for %{"event_id" => id, "text" => t} <- rows, t != "", into: %{}, do: {id, t}
      _ -> %{}
    end
  end
end
