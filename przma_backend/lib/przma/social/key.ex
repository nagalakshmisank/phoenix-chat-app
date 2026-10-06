defmodule Przma.Social.Key do
  @moduledoc """
  Builds every id the social services store. CouchDB record ids may only
  contain A-Z a-z 0-9 _ - (see CouchDocId), so a DID ("did:przma:alice")
  can never be used as-is.

    did_key/1      did:przma:kc_user1 -> "did_przma_kc_user1"
                   anything else      -> "x" <> hex(did)   (never collides)
    message_id/0   17 digits of microseconds + 6 random hex chars.
                   Sorting by id = sorting by time, so "newest first" and
                   "everything after X" are plain key-range reads.
    circle_id/0    16 hex chars, fixed length (safe to use as an id prefix)

  Thread keys (one chat list entry each):
    direct message   did_key(the other person)
    circle           "c_" <> circle_id
    notifications    "sys"

  Inbox/outbox record id = thread_key <> "-" <> message_id. "-" never
  appears inside a thread key or message id, so "thread-" is a safe prefix.
  """

  @readable ~r/^did:przma:[a-z0-9_]+$/

  @spec did_key(String.t()) :: String.t()
  def did_key(did) when is_binary(did) do
    if Regex.match?(@readable, did) do
      String.replace(did, ":", "_")
    else
      "x" <> Base.encode16(did, case: :lower)
    end
  end

  @spec message_id() :: String.t()
  def message_id do
    micros = System.os_time(:microsecond) |> Integer.to_string() |> String.pad_leading(17, "0")
    micros <> random_hex(3)
  end

  @spec circle_id() :: String.t()
  def circle_id, do: random_hex(8)

  @spec invite_code() :: String.t()
  def invite_code, do: random_hex(6)

  def dm_thread(peer_did), do: did_key(peer_did)
  def circle_thread(circle_id), do: "c_" <> circle_id
  def system_thread, do: "sys"

  @doc "Record id of one message inside a thread."
  def record(thread_key, message_id), do: thread_key <> "-" <> message_id

  @doc "Record-id prefix that matches every message of a thread."
  def thread_prefix(thread_key), do: thread_key <> "-"

  @doc "Splits an inbox/outbox record id back into {thread_key, message_id}."
  def split_record(record_id) do
    case String.split(record_id, "-", parts: 2) do
      [thread, msg] -> {thread, msg}
      [single] -> {single, single}
    end
  end

  @doc "A client-supplied id is accepted only if it is a valid record-id part without '-'."
  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_]{1,64}$/, id)

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
