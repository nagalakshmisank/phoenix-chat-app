defmodule Przma.Vault.PzdbAuthorization do
  @moduledoc """
  The authorization gate for pzdb:// access — implements the flowchart
  in pzdb_authorization_integration.md Section 4. Called by whatever
  thin connector wraps the existing Rustler NIF, BEFORE any LanceDB
  call happens — never after, and never inside the per-DID LanceWriter
  GenServer, so an unauthorized request never even reaches that
  serialized write queue.

  This module does not implement LanceDB access itself — it returns
  :ok | {:error, reason}, and the caller (PzdbConnector, not built
  here) is responsible for only proceeding to the actual NIF call on
  :ok.

  Personal vault ("vault" namespace) has exactly one exception to its
  otherwise-absolute owner-only rule: a live MemorialAccessGrant
  (session 6 — memorial succession), always read-only, populated only
  by SuccessionResolver after a real N-of-M trustee threshold — never
  by any grant, role, or admin action. See authorize_personal/3.
  """

  alias Przma.Federation.{PortableGrant, TrustPolicy}
  alias Przma.Vault.{NamespacePolicy, PzdbUri}

  @type operation :: :read | :write | :compact

  @doc """
  actor: %{did: String.t(), origin_instance_id: String.t() | nil,
           portable_grant: PortableGrant.t() | nil} — origin_instance_id
  nil means "this instance" (a local session, gated via
  CapabilityGrant); non-nil means the request arrived over Flight from
  elsewhere and must carry a portable_grant to be gated via
  PortableGrant.verify/1 + TrustPolicy instead.
  """
  @spec authorize(actor :: map(), uri :: PzdbUri.t(), operation()) :: :ok | {:error, atom()}
  def authorize(actor, %PzdbUri{} = uri, operation) do
    with :ok <- check_operation_ceiling(uri, operation) do
      if NamespacePolicy.personal?(uri.namespace) do
        authorize_personal(actor, uri, operation)
      else
        authorize_non_personal(actor, uri, operation)
      end
    end
  end

  # Runs before ownership/grant checks, for every namespace including
  # "vault" — this is "does this namespace support this operation at
  # all", not "is this actor allowed to do it". A namespace listed as
  # read-only stays read-only even for its own owner.
  # Runs before ownership/grant checks, for every namespace including
  # "vault" — this is "does this namespace support this operation at
  # all", not "is this actor allowed to do it". A namespace listed as
  # read-only stays read-only even for its own owner. "vault" is
  # intentionally exempt (not in @allowed_operations_by_namespace at
  # all) since it's fully owner-controlled by authorize_personal/3 —
  # this ceiling would otherwise silently block every profile write.
  defp check_operation_ceiling(%PzdbUri{namespace: "vault"}, _operation), do: :ok

  defp check_operation_ceiling(%PzdbUri{namespace: namespace}, operation) do
    if NamespacePolicy.operation_allowed?(namespace, operation) do
      :ok
    else
      {:error, :operation_not_allowed_for_namespace}
    end
  end

  # Personal vault: byte-identical DID match, OR a live
  # MemorialAccessGrant (session 6 — the ONLY exception to this rule,
  # and deliberately not via CapabilityGrant/PortableGrant/
  # ElevationRequest at all — a completely separate table, populated
  # only by SuccessionResolver after a real N-of-M trustee threshold.
  # No admin, root, or agent action can create this access any other
  # way. Memorial access is also always read-only — never checked
  # against `operation`, since it's hard-coded that way at the schema
  # level (memorial_access_grants.access_level check constraint), but
  # confirmed here too as defense in depth: a write attempt under a
  # memorial grant still falls through to the final `false` branch.
  defp authorize_personal(%{did: actor_did}, %PzdbUri{did: uri_did}, operation) do
    cond do
      actor_did == uri_did ->
        :ok

      operation == :read and Przma.Identity.MemorialAccessGrant.live_grant_exists?(uri_did, actor_did) ->
        :ok

      true ->
        {:error, :personal_vault_forbidden}
    end
  end

  defp authorize_non_personal(actor, %PzdbUri{} = uri, operation) do
    with {:ok, scope} <- resolve_scope(uri),
         verb <- NamespacePolicy.verb_for(uri.namespace, operation),
         :ok <- check_owner_or_grant(actor, uri, scope, verb) do
      :ok
    end
  end

  # DECISION (flag for supervisor): the owner of a non-personal space
  # (public/circle/professional) always has access to their OWN space,
  # no CapabilityGrant required — grants only govern OTHER DIDs reading
  # or writing into it. This intentionally bypasses check_grant/2
  # (Przma.Identity.live_grant_for/2 is a stub) and
  # check_tenant_governance/2 (needs AshPostgres — this build is
  # Lance-only, no Postgres, per the "No PostgreSQL" storage decision).
  # Non-owner access still requires a real grant once that system is
  # built; this only shortcuts the owner's own read/write.
  defp check_owner_or_grant(%{did: actor_did} = actor, %PzdbUri{did: uri_did} = uri, scope, verb) do
    if actor_did == uri_did do
      :ok
    else
      check_grant(actor, uri, scope, verb)
    end
  end

  # Circles (session 6 — vault_scope :public/:professional) own their
  # OWN vault_scope, independent of which namespace string is in the
  # URI — a Public circle's "notes" table is still :public, not the
  # :private NamespacePolicy would default it to for an ordinary
  # persona. Without this check, a circle's grants (issued at :public/
  # :professional scope) would never match what this function checked
  # against, and circles would silently never work — this was caught
  # and fixed while wiring circles in, not present in the original
  # session-5 version of this function.
  defp resolve_scope(%PzdbUri{did: did, namespace: namespace}) do
    case Przma.Identity.Circle.vault_scope_for(did) do
      {:ok, circle_scope} -> {:ok, circle_scope}
      :not_a_circle -> NamespacePolicy.vault_scope(namespace)
    end
  end

  # -- local vs. federated grant checking --------------------------------

  defp check_grant(%{origin_instance_id: nil} = actor, uri, scope, verb) do
    # Same-instance actor: existing CapabilityGrant path (session 2),
    # same function VaultPolicy already uses for every other resource.
    with {:ok, grant} <- Przma.Identity.live_grant_for(actor.did, scope),
         true <- verb in grant.verbs,
         true <- actor.did == uri.did do
      :ok
    else
      :error -> {:error, :no_live_grant}
      false -> {:error, :verb_not_in_grant_or_did_mismatch}
    end
  end

  defp check_grant(%{portable_grant: nil}, _uri, _scope, _verb) do
    {:error, :federated_request_missing_portable_grant}
  end

  defp check_grant(%{portable_grant: %PortableGrant{} = grant} = actor, uri, scope, verb) do
    # Federated actor: reuse PortableGrant.verify/1 + TrustPolicy
    # exactly as designed for general federation (session 3) — a
    # pzdb://flight/ request is not a special case, it's just another
    # thing a remote DID is asking this instance to authorize.
    with :ok <- PortableGrant.verify(grant),
         :ok <- confirm_grant_matches_request(grant, actor.did, uri.did, scope, verb),
         true <- TrustPolicy.verb_allowed_from_domain?(actor.did, verb) do
      :ok
    else
      false -> {:error, :verb_not_trusted_from_domain}
      {:error, _} = err -> err
    end
  end

  defp confirm_grant_matches_request(grant, actor_did, uri_did, scope, verb) do
    cond do
      grant.audience_did != actor_did -> {:error, :grant_not_issued_to_actor}
      grant.vault_scope != scope -> {:error, :grant_scope_mismatch}
      verb not in grant.verbs -> {:error, :verb_not_in_grant}
      actor_did != uri_did -> {:error, :grant_does_not_cover_target_did}
      true -> :ok
    end
  end
end
