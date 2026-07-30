defmodule PRZMAWeb.PeopleController do
  use PRZMAWeb, :controller
  alias PRZMA.Social.Follows

  def follow(conn, %{"did" => target_did}) do
    did = conn.assigns[:did]

    case Follows.follow(did, target_did) do
      {:ok, result} -> json(conn, result)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def approve(conn, %{"did" => follower_did}) do
    did = conn.assigns[:did]

    case Follows.approve_follow(did, follower_did) do
      {:ok, row} -> json(conn, row)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def deny(conn, %{"did" => follower_did}) do
    did = conn.assigns[:did]

    case Follows.deny_follow(did, follower_did) do
      {:ok, row} -> json(conn, row)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def pending(conn, _params) do
    did = conn.assigns[:did]

    case Follows.list_pending_follow_requests(did) do
      {:ok, rows} -> json(conn, %{pending: rows, count: length(rows)})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end
end
