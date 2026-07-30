defmodule PRZMA.Social.Contacts do
  @moduledoc """
  Contacts + contact classification + contact suggestions.
  From IMPLEMENTATION_GUIDE.md §2. Mirrors the structure of circle_sync.ex
  exactly (same dir_for/1, upsert/read_table private helpers).
  """

  alias PRZMA.PzDb.NIF
  alias PRZMA.Auth
  require Logger

  defp vault_base, do: Application.get_env(:przma, :vault_base_path, "s3://perkeep")
  defp dir_for(did), do: "#{vault_base()}/#{sanitize(did)}/social"
  defp sanitize(did), do: did |> String.replace(":", "_") |> String.replace(".", "_")

  # ── LOOKUP (source: lookup) ──────────────────────────────────────────
  # DID is computed deterministically — did:przma:<nickname> — same as
  # PRZMA.Auth.did_for/1. We still check the account exists before letting
  # the owner add it.
  def lookup_by_nickname(nickname) do
    did = Auth.did_for(nickname)
    case Auth.get_account(did) do
      {:ok, _account} -> {:ok, did}
      {:error, _} -> {:error, :not_found}
    end
  end

  # ── CREATE (manual / lookup / agent / invite / follow) ────────────────
  def add_contact(owner_did, attrs) do
    now = System.os_time(:microsecond)
    id = generate_contact_id(owner_did, attrs["contact_ref"])

    row = %{
      "id" => id,
      "owner_did" => owner_did,
      # "person" | "company" | "agent"
      "entity_type" => attrs["entity_type"],
      "contact_ref" => attrs["contact_ref"],
      "contact_ref_type" => attrs["contact_ref_type"] || "did",
      # nil = unclassified
      "contact_type_id" => attrs["contact_type_id"],
      "is_emergency_contact" => attrs["is_emergency_contact"] || false,
      "company_name" => attrs["company_name"],
      # manual|lookup|agent|invite|follow
      "source" => attrs["source"],
      "status" => "active",
      "created_at" => now,
      "updated_at" => now
    }

    with {:ok, _} <- upsert(owner_did, "contacts", row), do: {:ok, row}
  end

  # Used internally by CircleSync when a link-join is approved, or a follow
  # suggestion is approved, and no contact exists yet for that DID.
  def ensure_contact_for_did(owner_did, contact_ref, source) do
    case find_by_ref(owner_did, contact_ref) do
      {:ok, existing} ->
        {:ok, existing}

      {:error, :not_found} ->
        add_contact(owner_did, %{
          "entity_type" => "person",
          "contact_ref" => contact_ref,
          "contact_ref_type" => "did",
          "source" => source
        })
    end
  end

  def find_by_ref(owner_did, contact_ref) do
    with {:ok, rows} <- read_table(owner_did, "contacts") do
      case Enum.find(rows, &(&1["contact_ref"] == contact_ref and &1["status"] == "active")) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  def get_contact(owner_did, contact_id) do
    with {:ok, rows} <- read_table(owner_did, "contacts") do
      case Enum.find(rows, &(&1["id"] == contact_id)) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  def list_contacts(owner_did) do
    with {:ok, rows} <- read_table(owner_did, "contacts") do
      {:ok, Enum.filter(rows, &(&1["status"] == "active"))}
    end
  end

  # ── CLASSIFY ──────────────────────────────────────────────────────────
  def classify_contact(owner_did, contact_id, contact_type_id) do
    with {:ok, row} <- get_contact(owner_did, contact_id) do
      updated =
        Map.merge(row, %{
          "contact_type_id" => contact_type_id,
          "updated_at" => System.os_time(:microsecond)
        })

      with {:ok, _} <- upsert(owner_did, "contacts", updated), do: {:ok, updated}
    end
  end

  # ── CONTACT TYPES ─────────────────────────────────────────────────────
  @system_types ["friend", "family", "colleague", "related_person", "ai_contact"]

  def list_contact_types(owner_did) do
    with {:ok, rows} <- read_table(owner_did, "contact_types") do
      custom = Enum.filter(rows, &(&1["owner_did"] == owner_did))
      {:ok, system_type_rows() ++ custom}
    end
  end

  defp system_type_rows do
    Enum.map(@system_types, fn name ->
      %{"id" => "system_#{name}", "owner_did" => nil, "name" => name, "is_system" => true}
    end)
  end

  def create_custom_contact_type(owner_did, name, description \\ nil) do
    row = %{
      "id" => "ct_#{owner_did |> sanitize()}_#{name}",
      "owner_did" => owner_did,
      "name" => name,
      "description" => description,
      "is_system" => false
    }

    with {:ok, _} <- upsert(owner_did, "contact_types", row), do: {:ok, row}
  end

  # ── SUGGESTIONS (owner-consent step for follow / other future sources) ─
  def create_suggestion(owner_did, suggested_contact_ref, entity_type \\ "person", source \\ "follow") do
    id = "sugg_#{sanitize(owner_did)}_#{sanitize(suggested_contact_ref)}"

    row = %{
      "id" => id,
      "owner_did" => owner_did,
      "suggested_contact_ref" => suggested_contact_ref,
      "entity_type" => entity_type,
      "source" => source,
      "status" => "pending",
      "created_at" => System.os_time(:microsecond)
    }

    upsert(owner_did, "contact_suggestions", row)
  end

  def list_pending_suggestions(owner_did) do
    with {:ok, rows} <- read_table(owner_did, "contact_suggestions") do
      {:ok, Enum.filter(rows, &(&1["status"] == "pending"))}
    end
  end

  def approve_suggestion(owner_did, suggestion_id) do
    with {:ok, rows} <- read_table(owner_did, "contact_suggestions"),
         suggestion when not is_nil(suggestion) <- Enum.find(rows, &(&1["id"] == suggestion_id)),
         {:ok, contact} <-
           add_contact(owner_did, %{
             "entity_type" => suggestion["entity_type"],
             "contact_ref" => suggestion["suggested_contact_ref"],
             "contact_ref_type" => "did",
             "source" => "follow"
           }) do
      updated = Map.merge(suggestion, %{"status" => "approved"})
      upsert(owner_did, "contact_suggestions", updated)
      {:ok, contact}
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end

  def dismiss_suggestion(owner_did, suggestion_id) do
    with {:ok, rows} <- read_table(owner_did, "contact_suggestions"),
         suggestion when not is_nil(suggestion) <- Enum.find(rows, &(&1["id"] == suggestion_id)) do
      upsert(owner_did, "contact_suggestions", Map.put(suggestion, "status", "dismissed"))
    else
      nil -> {:error, :not_found}
    end
  end

  # ── PRIVATE ───────────────────────────────────────────────────────────
  defp generate_contact_id(owner_did, contact_ref),
    do: :crypto.hash(:sha256, "#{owner_did}:#{contact_ref}") |> Base.encode16(case: :lower)

  defp upsert(did, table, row) do
    case NIF.pzdb_upsert(dir_for(did), table, Jason.encode!(row), Jason.encode!(["id"])) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      json when is_binary(json) -> {:ok, Jason.decode!(json)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_table(did, table) do
    case NIF.pzdb_read_many(dir_for(did), table, "", 500, 0) do
      {:ok, json} -> {:ok, decode(json)}
      json when is_binary(json) -> {:ok, decode(json)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(json) when is_binary(json), do: decode(Jason.decode!(json))
  defp decode(%{"records" => records}) when is_list(records), do: records
  defp decode(list) when is_list(list), do: list
  defp decode(_), do: []
end
