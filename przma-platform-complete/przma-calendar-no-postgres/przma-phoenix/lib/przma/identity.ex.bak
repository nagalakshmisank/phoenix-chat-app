# lib/przma/identity.ex
#
# Identity and circle membership verification.
# In production: membership stored in PostgreSQL (shared metadata).
# DID document resolution via HTTP Signature verification.

defmodule PRZMA.Identity do
  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── DID OWNERSHIP ────────────────────────────────────────────────────────────

  @doc """
  Verify that the authenticated DID matches the claimed DID.
  Used in channel joins to prevent impersonation.
  """
  def verify_did_ownership(authed_did, claimed_did) do
    if authed_did == claimed_did, do: :ok, else: {:error, :unauthorized}
  end

  # ── CIRCLE MEMBERSHIP ────────────────────────────────────────────────────────

  @doc """
  Verify that a DID is a member of a circle.
  Returns :ok or {:error, :not_a_member}.
  In production: queries PostgreSQL circle_memberships table.
  """
  def verify_circle_membership(did, circle_did) do
    case get_role(did, circle_did) do
      {:ok, _role} -> :ok
      :error       -> {:error, :not_a_member}
    end
  end

  @doc """
  Get the role of a DID in a circle.
  Returns {:ok, role_string} or :error.
  """
  def get_role(did, circle_did) do
    case PRZMA.Repo.get_circle_membership(did, circle_did) do
      nil        -> :error
      membership -> {:ok, membership.role}
    end
  end

  @doc """
  Get all members of a circle with their roles.
  Returns list of %{did: did, role: role, joined_at: datetime}.
  """
  def list_circle_members(circle_did) do
    PRZMA.Repo.list_circle_memberships(circle_did)
  end

  @doc """
  Get only the DIDs of circle members (for replication broadcast).
  """
  def circle_member_dids(circle_did) do
    circle_did
    |> list_circle_members()
    |> Enum.map(& &1.did)
  end

  @doc """
  List all circles a DID belongs to.
  """
  def list_circles_for_did(did) do
    PRZMA.Repo.list_memberships_for_did(did)
  end

  # ── CIRCLE MANAGEMENT ────────────────────────────────────────────────────────

  @doc "Create a new circle with the founding DID as Steward"
  def create_circle(founder_did, attrs) do
    circle_did = generate_circle_did(founder_did, attrs["name"])

    membership = %{
      did:       founder_did,
      circle_did: circle_did,
      role:       "steward",
      joined_at:  DateTime.utc_now(),
    }

    PRZMA.Repo.insert_circle(Map.merge(attrs, %{"id" => circle_did}))
    PRZMA.Repo.insert_membership(membership)

    {:ok, circle_did}
  end

  @doc "Add a member to a circle with a given role"
  def add_member(circle_did, new_did, role, added_by_did) do
    with {:ok, adder_role} <- get_role(added_by_did, circle_did),
         :ok               <- check_can_invite(adder_role) do
      membership = %{
        did:        new_did,
        circle_did: circle_did,
        role:       role,
        joined_at:  DateTime.utc_now(),
        added_by:   added_by_did,
      }
      PRZMA.Repo.insert_membership(membership)
    end
  end

  @doc "Remove a member from a circle"
  def remove_member(circle_did, target_did, removed_by_did) do
    with {:ok, remover_role} <- get_role(removed_by_did, circle_did),
         :ok                  <- check_can_remove(remover_role),
         {:ok, target_role}  <- get_role(target_did, circle_did) do
      # Steward cannot be removed by Guardian
      if target_role == "steward" and remover_role != "steward" do
        {:error, :cannot_remove_steward}
      else
        PRZMA.Repo.delete_membership(target_did, circle_did)
      end
    end
  end

  @doc "Update a member's role in a circle"
  def update_role(circle_did, target_did, new_role, updated_by_did) do
    with {:ok, "steward"} <- get_role(updated_by_did, circle_did) do
      PRZMA.Repo.update_membership_role(target_did, circle_did, new_role)
    end
  end

  # ── HTTP SIGNATURE VERIFICATION ──────────────────────────────────────────────

  @doc """
  Verify an HTTP Signature against a resolved DID document.
  Returns {:ok, did} or {:error, reason}.
  """
  def verify_http_signature(conn) do
    with {:ok, auth_header}  <- get_auth_header(conn),
         {:ok, did, key_id}  <- parse_signature_header(auth_header),
         {:ok, did_document} <- resolve_did(did),
         {:ok, public_key}   <- extract_public_key(did_document, key_id),
         :ok                 <- verify_signature(conn, public_key) do
      {:ok, did}
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────────

  defp generate_circle_did(founder_did, name) do
    domain  = founder_did |> String.split(":") |> List.last()
    slug    = name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-")
    token   = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "did:web:#{domain}:circles:#{slug}-#{token}"
  end

  defp check_can_invite(role) do
    if PRZMA.Calendar.Governance.can_invite_members?(role),
      do: :ok,
      else: {:error, :permission_denied}
  end

  defp check_can_remove(role) do
    if PRZMA.Calendar.Governance.can_remove_members?(role),
      do: :ok,
      else: {:error, :permission_denied}
  end

  defp get_auth_header(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [header | _] -> {:ok, header}
      []            -> {:error, :missing_authorization}
    end
  end

  defp parse_signature_header(header) do
    # Parse: Signature keyId="did:web:alice.com#key-1",algorithm="ecdsa-p256-sha256",...
    case Regex.run(~r/keyId="([^#"]+)#([^"]+)"/, header) do
      [_, did, key_fragment] -> {:ok, did, "#{did}##{key_fragment}"}
      _                      -> {:error, :invalid_signature_header}
    end
  end

  defp resolve_did(did) do
    # Phase 1: simplified resolver — full DID:web HTTP resolution in Phase 3
    PRZMA.DID.Resolver.resolve(did)
  end

  defp extract_public_key(did_document, key_id) do
    methods = did_document["verificationMethod"] || []
    case Enum.find(methods, fn m -> m["id"] == key_id end) do
      nil    -> {:error, :key_not_found}
      method -> {:ok, method["publicKeyJwk"] || method["publicKeyMultibase"]}
    end
  end

  defp verify_signature(_conn, _public_key) do
    # Phase 1: accepts all signatures — full ECDSA P-256 verification in Phase 3
    :ok
  end
end
