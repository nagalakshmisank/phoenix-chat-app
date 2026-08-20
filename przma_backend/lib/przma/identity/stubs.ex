defmodule Przma.Identity.MemorialAccessGrant do
  @moduledoc """
  STUB — the memorial/succession access-grant system referenced by
  PzdbAuthorization.authorize_personal/3 isn't built yet. Fails
  closed: no memorial grant is ever considered live, so this exception
  path in authorize_personal/3 never opens for anyone but the owner.
  Replace with a real implementation when memorial succession is built.
  """
  @spec live_grant_exists?(owner_did :: String.t(), requester_did :: String.t()) :: boolean()
  def live_grant_exists?(_owner_did, _requester_did), do: false
end

defmodule Przma.Identity.Circle do
  @moduledoc """
  STUB — no circle system is built yet, so no DID is ever resolved as
  a circle. PzdbAuthorization.resolve_scope/1 always falls through to
  NamespacePolicy.vault_scope/1 as a result. Replace when circles ship.
  """
  @spec vault_scope_for(did :: String.t()) :: :not_a_circle
  def vault_scope_for(_did), do: :not_a_circle
end

defmodule Przma.Identity do
  @moduledoc """
  STUB — live_grant_for/2 is the one function IMPLEMENTATION_STATUS.md
  in the mentor's zip flags as unimplemented everywhere it's
  referenced. Kept as a stub here so the project compiles; it's only
  reached for NON-owner access to public/circle/professional spaces
  (the owner path never calls it, per the owner-bypass in
  PzdbAuthorization.check_owner_or_grant/4). Replace with a real
  CapabilityGrant lookup once that system is designed — see the
  persona/agent discussion this project's chat history covered.
  """
  @spec live_grant_for(did :: String.t(), scope :: :private | :social) ::
          {:ok, map()} | {:error, :not_implemented}
  def live_grant_for(_did, _scope), do: {:error, :not_implemented}
end
