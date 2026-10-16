defmodule Przma.Search.Indexer do
  @moduledoc """
  Background indexing, so uploads and messages never wait for search.

  Each call starts a task under Przma.Search.TaskSupervisor and returns :ok
  at once. Failures are only logged: search is a helper, it must never break
  an upload or a message.

      Indexer.index_file_async(did, file_id, "notes.pdf", "application/pdf", bytes, "private")
      Indexer.index_text_async(did, %{type: "chat", id: msg_id, title: "Chat with Priya"}, text)

  Off by default. Turned on with config :przma, :search, auto_index: true
  (runtime.exs reads SEARCH_AUTO_INDEX=true).
  """

  require Logger

  alias Przma.Search
  alias Przma.Search.TextExtract

  @sup Przma.Search.TaskSupervisor

  @doc "Extracts text from an uploaded file's bytes and indexes it (txt/md/csv/pdf …)."
  def index_file_async(did, file_id, filename, mime, bytes, space \\ "private") do
    if enabled?() and TextExtract.supported?(filename, mime) do
      start(fn ->
        with {:ok, text} <- TextExtract.from_binary(bytes, filename, mime),
             {:ok, res} <- Search.index_text(did, %{type: "file", id: file_id, title: filename}, text, space: space) do
          Logger.info("search: indexed file #{file_id} (#{res.chunks} pieces) for #{did}")
        else
          {:error, reason} -> Logger.warning("search: file #{file_id} not indexed: #{inspect(reason)}")
        end
      end)
    else
      :skipped
    end
  end

  @doc "Indexes a piece of text (chat message, note …) without replacing older pieces."
  def index_text_async(did, source, text, opts \\ []) do
    if enabled?() and String.trim(text) != "" do
      start(fn ->
        case Search.index_text(did, source, text, Keyword.put_new(opts, :replace, false)) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.warning("search: #{source.type} #{source.id} not indexed: #{inspect(reason)}")
        end
      end)
    else
      :skipped
    end
  end

  defp start(fun) do
    case Task.Supervisor.start_child(@sup, fun) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.warning("search: indexer not started: #{inspect(reason)}")
    end
  end

  defp enabled?, do: Keyword.get(Application.get_env(:przma, :search, []), :auto_index, false)
end
