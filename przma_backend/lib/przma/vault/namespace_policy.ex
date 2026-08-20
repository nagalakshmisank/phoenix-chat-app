defmodule Przma.Vault.NamespacePolicy do
  @moduledoc """
  Maps the raw LanceDB namespace strings already in use (moments,
  holnn, notes, calendar, chat, social, vault — from the pzdb://
  examples in prior sessions) onto this conversation's vault_scope
  enum (:private | :social), plus the one namespace that isn't
  mappable at all: `vault` IS Personal vault. Not "maps to something
  like personal" — it is the literal namespace name already in use for
  it in the real URI scheme.

  This mapping table is deliberately the ONLY place namespace strings
  are interpreted — PzdbAuthorization calls into this rather than
  duplicating the mapping, so there's one place to update if a new
  namespace is added.
  """

  @vault_scope_by_namespace %{
    "moments" => :private,
    "holnn" => :private,
    "notes" => :private,
    "calendar" => :private,
    "chat" => :social,
    "social" => :social,
    # Added for flow orchestration: step output addressing
    # (pzdb://.../workflow/{flow_run_id}/step_{n}) — private by
    # default since a flow's intermediate output isn't automatically
    # shareable just because the flow itself involves multiple agents;
    # a step that should produce shareable output writes to "social"
    # (or another namespace) explicitly instead.
    "workflow" => :private,
    # Domain 3 additions: files (blob/S3 storage via existing CAS
    # path — BLAKE3 CID = S3 key, per prior sessions) and practices
    # (PRZMA Vault v2.0's Practices/Rituals tracking). Both private by
    # default — a file or practice log isn't shareable just by
    # existing; sharing happens by writing to a circle-scoped
    # namespace/table instead (see Circle integration below), not by
    # this default changing.
    "files" => :private,
    "practices" => :private,
    # Registration-time spaces (session N): every user gets these 3
    # non-personal spaces provisioned at registration, alongside the
    # always-present "vault" (private) space above. "vault" itself
    # already covers profile storage — no separate "profile" namespace
    # needed; profile is a table INSIDE "vault", see Przma.Vault.Profile.
    "public" => :social,
    "circle" => :social,
    "professional" => :social
  }

  @personal_namespace "vault"

  @doc "Whether this namespace is the hard-coded Personal-vault boundary — never reachable via any grant, ever."
  @spec personal?(namespace :: String.t()) :: boolean()
  def personal?(@personal_namespace), do: true
  def personal?(_other), do: false

  @doc """
  The vault_scope a namespace maps to, for grant/governance checks.
  Returns an error for the personal namespace or an unrecognized one —
  callers must check personal?/1 FIRST and refuse outright regardless
  of what this returns; this never yields a usable scope for it, so a
  caller that skips the personal?/1 check still fails closed instead
  of accidentally treating it as an ordinary :private scope.
  """
  @spec vault_scope(namespace :: String.t()) :: {:ok, :private | :social} | {:error, atom()}
  def vault_scope(namespace) do
    cond do
      personal?(namespace) -> {:error, :personal_namespace_has_no_grantable_scope}
      Map.has_key?(@vault_scope_by_namespace, namespace) -> {:ok, Map.fetch!(@vault_scope_by_namespace, namespace)}
      true -> {:error, :unknown_namespace}
    end
  end

  @doc """
  Per-namespace operation CEILING — independent of, and checked before,
  any grant. vault_scope/1 only decides which grant BUCKET a namespace
  needs; nothing previously stopped a grant from containing a verb for
  an operation that namespace was never meant to support at all (e.g.
  nothing stopped "vault.calendar.write" from being issued and honored
  even if calendar is meant to be read-only for everyone, always).
  This table is that missing ceiling — a grant can never unlock an
  operation not listed here for its namespace, full stop.

  "vault" (personal) is intentionally NOT in this table — it has its
  own unconditional owner-only rule in PzdbAuthorization.authorize_personal/3
  and was never grant-gated in the first place, so a ceiling here would
  be redundant with, not additive to, that rule.

  CAUTION — calendar is listed read-only below to match the example
  given when this table was designed, but lib/przma/vault/calendar.ex
  currently has its own write actions (creating/updating events). If
  calendar is meant to stay writable through that module, either this
  entry needs [:read, :write] or calendar.ex's writes need to go
  through a different namespace than "calendar" — confirm before
  deploying, this WILL break calendar.ex's writes as currently listed.
  """
  @allowed_operations_by_namespace %{
    "moments" => [:read, :write, :compact],
    "holnn" => [:read, :write, :compact],
    "notes" => [:read, :write, :compact],
    "calendar" => [:read],
    "chat" => [:read, :write],
    "social" => [:read, :write, :compact],
    "workflow" => [:read, :write],
    "files" => [:read, :write, :compact],
    "practices" => [:read, :write, :compact],
    "public" => [:read, :write],
    "circle" => [:read, :write],
    "professional" => [:read, :write]
  }

  @doc """
  Whether a namespace supports a given operation at all, regardless of
  any grant. Unknown namespace -> false (fails closed, same posture as
  vault_scope/1's :unknown_namespace error).
  """
  @spec operation_allowed?(namespace :: String.t(), operation :: :read | :write | :compact) :: boolean()
  def operation_allowed?(namespace, operation) do
    operation in Map.get(@allowed_operations_by_namespace, namespace, [])
  end

  @doc "Builds the VerbRegistry-style verb string for a namespace + operation, per the design doc's Section 3 mapping."
  @spec verb_for(namespace :: String.t(), operation :: :read | :write | :compact) :: String.t()
  def verb_for(namespace, operation), do: "vault.#{namespace}.#{operation}"
end
