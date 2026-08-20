defmodule Przma.Federation.PortableGrant do
  @moduledoc """
  STUB struct — federation (cross-instance access via Flight) isn't
  built in this project. Every actor map this codebase constructs sets
  portable_grant: nil, so PzdbAuthorization.check_grant/4's federated
  clause (which pattern-matches on this struct) is defined for
  compilation but never actually reached at runtime here.
  """
  defstruct [:audience_did, :vault_scope, :verbs]

  @spec verify(t :: t()) :: :ok | {:error, :not_implemented}
  def verify(_grant), do: {:error, :not_implemented}

  @type t :: %__MODULE__{}
end

defmodule Przma.Federation.TrustPolicy do
  @moduledoc """
  STUB — no federation trust policy exists yet. Always denies, so if
  the federated grant path in PzdbAuthorization were ever reached
  (it isn't, in this build — see PortableGrant's moduledoc), it fails
  closed rather than silently allowing.
  """
  @spec verb_allowed_from_domain?(did :: String.t(), verb :: String.t()) :: boolean()
  def verb_allowed_from_domain?(_did, _verb), do: false
end
