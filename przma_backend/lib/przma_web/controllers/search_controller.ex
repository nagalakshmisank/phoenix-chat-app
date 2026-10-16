defmodule PRZMAWeb.SearchController do
  @moduledoc """
  REST API for search. The user is ALWAYS the logged-in user
  (conn.assigns.did from KeycloakAuth); a did in params is ignored.

      GET  /api/v1/search?q=hill+station&mode=hybrid&limit=5&space=private&source_type=file
      POST /api/v1/search/index   {"text": "...", "source_type": "doc", "source_id": "n1", "title": "My note"}
      GET  /api/v1/search/stats?space=private
  """

  use PRZMAWeb, :controller

  alias Przma.Search

  @modes %{"vector" => :vector, "keyword" => :keyword, "hybrid" => :hybrid}
  @spaces ~w(private personal public)

  def search(conn, %{"q" => q} = params) when is_binary(q) and q != "" do
    opts =
      [
        mode: Map.get(@modes, params["mode"], :vector),
        limit: params |> Map.get("limit", "10") |> to_int(10) |> min(50),
        space: space(params)
      ] ++ if(params["source_type"], do: [source_type: params["source_type"]], else: [])

    case Search.search(conn.assigns.did, q, opts) do
      {:ok, res} -> json(conn, res)
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def search(conn, _params), do: conn |> put_status(400) |> json(%{error: "q is required"})

  def index(conn, %{"text" => text} = params) when is_binary(text) and text != "" do
    source = %{
      type: Map.get(params, "source_type", "doc"),
      id: Map.get(params, "source_id") || "doc_" <> Integer.to_string(System.unique_integer([:positive])),
      title: params["title"]
    }

    case Search.index_text(conn.assigns.did, source, text, space: space(params)) do
      {:ok, res} -> json(conn, res)
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def index(conn, _params), do: conn |> put_status(400) |> json(%{error: "text is required"})

  def stats(conn, params) do
    case Search.stats(conn.assigns.did, space(params)) do
      {:ok, res} -> json(conn, res)
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  defp space(params), do: if(params["space"] in @spaces, do: params["space"], else: "private")

  defp to_int(v, _d) when is_integer(v), do: v

  defp to_int(v, d) do
    case Integer.parse(to_string(v)) do
      {n, _} when n > 0 -> n
      _ -> d
    end
  end
end
