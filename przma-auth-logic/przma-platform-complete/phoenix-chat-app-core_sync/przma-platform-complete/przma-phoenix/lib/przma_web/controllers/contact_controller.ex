defmodule PRZMAWeb.ContactController do
  use PRZMAWeb, :controller
  alias PRZMA.Social.Contacts

  def lookup(conn, %{"nickname" => nickname}) do
    case Contacts.lookup_by_nickname(nickname) do
      {:ok, did} -> json(conn, %{did: did, found: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  def create(conn, params) do
    did = conn.assigns[:did]
    case Contacts.add_contact(did, params) do
      {:ok, contact} -> json(conn, contact)
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def index(conn, _params) do
    did = conn.assigns[:did]
    case Contacts.list_contacts(did) do
      {:ok, rows} -> json(conn, %{contacts: rows, count: length(rows)})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def classify(conn, %{"contact_id" => contact_id, "contact_type_id" => type_id}) do
    did = conn.assigns[:did]
    case Contacts.classify_contact(did, contact_id, type_id) do
      {:ok, contact} -> json(conn, contact)
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def types(conn, _params) do
    did = conn.assigns[:did]
    case Contacts.list_contact_types(did) do
      {:ok, rows} -> json(conn, %{contact_types: rows})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def suggestions(conn, _params) do
    did = conn.assigns[:did]
    case Contacts.list_pending_suggestions(did) do
      {:ok, rows} -> json(conn, %{suggestions: rows, count: length(rows)})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def approve_suggestion(conn, %{"suggestion_id" => id}) do
    did = conn.assigns[:did]
    case Contacts.approve_suggestion(did, id) do
      {:ok, contact} -> json(conn, contact)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def dismiss_suggestion(conn, %{"suggestion_id" => id}) do
    did = conn.assigns[:did]
    case Contacts.dismiss_suggestion(did, id) do
      {:ok, _} -> json(conn, %{status: "dismissed"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end
end
