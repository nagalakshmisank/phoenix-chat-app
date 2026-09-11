defmodule Przma.Vault.PzdbAuthorization do
  @moduledoc """
  The authorization gate for pzdb:// access — ONE funnel, no
  personal/non-personal split. Every request, regardless of namespace
  or space, runs through the exact same 3 steps:

    1. Ceiling check — can this namespace do this operation at all?
    2. Ownership check — is the actor the same DID as the target?
    3. If not the owner: is this space even grantable at all
       (personal_space?/1 — false for "personal", true otherwise),
       and if so, does a live grant cover the needed verb?

  "Personal" is a property of a SPACE value, checked as one branch
  inside step 3 — not a separate function, not a separate code path.
  A "personal" space differs from "private"/"public" ONLY in that step
  3 short-circuits to deny (plus the narrow memorial-read exception)
  instead of proceeding to an actual grant lookup — everything upstream
  of that point is identical for every space.

  Called by whatever thin connector wraps the existing Rustler NIF,
  BEFORE any LanceDB call happens — never after.
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
      check_owner_or_grant(actor, uri, operation)
    end
  end

  # Step 1 — runs before ownership/grant checks, for every namespace
  # and every space uniformly. A namespace listed as read-only stays
  # read-only even for its own owner, even in its "personal" space.
  defp check_operation_ceiling(%PzdbUri{namespace: namespace}, operation) do
    if NamespacePolicy.operation_allowed?(namespace, operation) do
      :ok
    else
      {:error, :operation_not_allowed_for_namespace}
    end
  end

  # Step 2 + 3 — ONE function, every space goes through it. This is
  # the whole funnel: own it -> :ok. Don't own it and it's a "personal"
  # space -> deny (memorial read is the one narrow exception). Don't
  # own it and it's grantable ("private"/"public") -> check for a
  # real grant.
  defp check_owner_or_grant(%{did: actor_did} = actor, %PzdbUri{did: uri_did} = uri, operation) do
    cond do
      actor_did == uri_did ->
        :ok

      NamespacePolicy.personal_space?(uri.space) ->
        memorial_exception(uri_did, actor_did, operation)

      true ->
        with {:ok, scope} <- resolve_scope(uri),
             verb <- NamespacePolicy.verb_for(uri.namespace, operation) do
          check_grant(actor, uri, scope, verb)
        end
    end
  end

  # The ONLY exception to a "personal" space's otherwise-absolute
  # owner-only rule: a live MemorialAccessGrant (session 6 — memorial
  # succession), always read-only, populated only by SuccessionResolver
  # after a real N-of-M trustee threshold — never by any grant, role,
  # or admin action. Deliberately not routed through check_grant/4 at
  # all — a completely separate table, so a bug in the ordinary grant
  # system can never accidentally leak into personal spaces.
  defp memorial_exception(uri_did, actor_did, :read) do
    if Przma.Identity.MemorialAccessGrant.live_grant_exists?(uri_did, actor_did) do
      :ok
    else
      {:error, :personal_space_forbidden}
    end
  end

  defp memorial_exception(_uri_did, _actor_did, _other_operation) do
    {:error, :personal_space_forbidden}
  end

  # Circles (session 6 — vault_scope :public/:professional) own their
  # OWN vault_scope, independent of which namespace string is in the
  # URI — a Public circle's "notes" table is still :public, not the
  # :private NamespacePolicy would default it to for an ordinary
  # persona. Without this check, a circle's grants (issued at :public/
  # :professional scope) would never match what this function checked
  # against, and circles would silently never work.
  defp resolve_scope(%PzdbUri{did: did, namespace: namespace}) do
    case Przma.Identity.Circle.vault_scope_for(did) do
      {:ok, circle_scope} -> {:ok, circle_scope}
      :not_a_circle -> NamespacePolicy.vault_scope(namespace)
    end
  end

  # -- local vs. federated grant checking --------------------------------

  defp check_grant(%{origin_instance_id: nil} = actor, _uri, scope, verb) do
    with {:ok, grant} <- Przma.Identity.live_grant_for(actor.did, scope),
         true <- verb in grant.verbs do
      :ok
    else
      :error -> {:error, :no_live_grant}
      {:error, _} -> {:error, :no_live_grant}
      false -> {:error, :verb_not_in_grant}
    end
  end

  defp check_grant(%{portable_grant: nil}, _uri, _scope, _verb) do
    {:error, :federated_request_missing_portable_grant}
  end

  defp check_grant(%{portable_grant: %PortableGrant{} = grant} = actor, uri, scope, verb) do
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