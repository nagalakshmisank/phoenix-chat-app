defmodule Przma.Social.Contacts do
  @moduledoc """
  The caller's address book, in the caller's own database:

      social:private:contacts:{did_key}        one document per contact
      social:private:contact_types:{slug}      the caller's custom labels

  Two ways a contact is created (field `source`):
    "direct"  the user typed/looked up a DID                 -> add/3
    "follow"  the user accepted one of their followers       -> add_from_follower/2
  (Circle approval by the owner also adds one, source "circle".)

  Adding a contact writes nothing to the other user.
  """

  alias Przma.Social.{Directory, Follows, Key, Store}

  @system_types ~w(friend family colleague related_person ai_contact)

  def add(%{did: owner}, contact_did, opts \\ []) do
    with :ok <- check(contact_did != owner, :cannot_add_yourself),
         {:ok, account} <- Directory.account(contact_did),
         :ok <- check_type(owner, opts[:contact_type]) do
      fields =
        %{
          "contact_did" => contact_did,
          "nickname" => account["nickname"],
          "display_name" => account["display_name"],
          "source" => Keyword.get(opts, :source, "direct"),
          "status" => "active",
          "added_at" => System.os_time(:microsecond)
        }
        |> put_present("contact_type", opts[:contact_type])

      with :ok <- Store.put(owner, "social", "contacts", Key.did_key(contact_did), fields) do
        get(owner, contact_did)
      end
    end
  end

  @doc "Adds one of the caller's active followers as a contact."
  def add_from_follower(%{did: owner} = me, follower_did) do
    with {:ok, %{"follow_status" => "active"}} <- Follows.follower(owner, follower_did) do
      add(me, follower_did, source: "follow")
    else
      _ -> {:error, :not_a_follower}
    end
  end

  @doc "Keeps an existing contact as it is, otherwise adds one with the given source."
  def ensure(%{did: owner} = me, contact_did, source) do
    case get(owner, contact_did) do
      {:ok, contact} -> {:ok, contact}
      _ -> add(me, contact_did, source: source)
    end
  end

  def get(owner, contact_did) do
    case Store.get(owner, "social", "contacts", Key.did_key(contact_did)) do
      {:ok, %{"status" => "active"} = contact} -> {:ok, contact}
      _ -> {:error, :not_found}
    end
  end

  def list(owner, contact_type \\ nil) do
    with {:ok, rows} <- Store.list(owner, "social", "contacts", limit: 1000) do
      {:ok,
       rows
       |> Enum.filter(&(&1["status"] == "active"))
       |> Enum.filter(&(is_nil(contact_type) or &1["contact_type"] == contact_type))
       |> Enum.sort_by(&(&1["display_name"] || &1["nickname"] || &1["contact_did"]))}
    end
  end

  def remove(%{did: owner}, contact_did) do
    with {:ok, _} <- get(owner, contact_did),
         :ok <- Store.put(owner, "social", "contacts", Key.did_key(contact_did), %{"status" => "removed"}) do
      {:ok, %{"contact_did" => contact_did, "status" => "removed"}}
    end
  end

  def classify(%{did: owner}, contact_did, contact_type) do
    with {:ok, _} <- get(owner, contact_did),
         :ok <- check_type(owner, contact_type),
         :ok <-
           Store.put(owner, "social", "contacts", Key.did_key(contact_did), %{"contact_type" => contact_type}) do
      get(owner, contact_did)
    end
  end

  # ── contact types ────────────────────────────────────────────────────

  def types(owner) do
    with {:ok, custom} <- Store.list(owner, "social", "contact_types", limit: 1000) do
      system = Enum.map(@system_types, &%{"name" => &1, "is_system" => true})
      {:ok, system ++ Enum.map(custom, &Map.put(&1, "is_system", false))}
    end
  end

  def create_type(%{did: owner}, name, description \\ nil) do
    slug = name |> to_string() |> String.trim() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

    with :ok <- check(slug != "" and slug != "_", :invalid_name),
         :ok <- check(slug not in @system_types, :already_exists),
         :ok <- Store.put(owner, "social", "contact_types", slug, %{"name" => slug, "description" => description}) do
      {:ok, %{"name" => slug, "description" => description, "is_system" => false}}
    end
  end

  # ── private ──────────────────────────────────────────────────────────

  defp check_type(_owner, nil), do: :ok
  defp check_type(_owner, type) when type in @system_types, do: :ok

  defp check_type(owner, type) when is_binary(type) do
    with true <- Key.valid_id?(type),
         {:ok, _} <- Store.get(owner, "social", "contact_types", type) do
      :ok
    else
      _ -> {:error, :unknown_contact_type}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
