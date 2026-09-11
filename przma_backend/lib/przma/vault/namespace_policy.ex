defmodule Przma.Vault.NamespacePolicy do
  @moduledoc """
  Maps namespace (service) strings onto this conversation's vault_scope
  enum (:private | :social) and per-namespace operation ceilings.

  As of the generic-namespace redesign, "personal" is no longer a
  hard-coded namespace name (the old special case for "vault") — it's
  a SPACE value, checked via personal_space?/1, and applies uniformly
  to any namespace's "personal" space. "vault" is now an ordinary
  namespace like any other, with its own vault_scope/ceiling entries
  below, same as "files" or "chat".

  This mapping table is deliberately the ONLY place namespace strings
  are interpreted — PzdbAuthorization calls into this rather than
  duplicating the mapping, so there's one place to update if a new
  namespace is added.
  """

  @vault_scope_by_namespace %{
    "vault" => :private,
    "moments" => :private,
    "holnn" => :private,
    "notes" => :private,
    "calendar" => :private,
    "chat" => :social,
    "social" => :social,
    "workflow" => :private,
    "files" => :private,
    "practices" => :private,
    "public" => :social,
    "circle" => :social,
    "professional" => :social
  }

  @personal_space "personal"

  @doc """
  Whether this SPACE value is the absolute, never-grantable boundary —
  applies uniformly across every namespace (a "personal" space in
  "vault" and a "personal" space in "files" carry the identical
  guarantee: owner-only, no grant can ever reach it, no exceptions
  besides the narrow memorial case).
  """
  @spec personal_space?(space :: String.t()) :: boolean()
  def personal_space?(@personal_space), do: true
  def personal_space?(_other), do: false

  @doc """
  The vault_scope a namespace maps to, for grant/governance checks.
  Unrecognized namespace -> error, fails closed.
  """
  @spec vault_scope(namespace :: String.t()) :: {:ok, :private | :social} | {:error, atom()}
  def vault_scope(namespace) do
    case Map.fetch(@vault_scope_by_namespace, namespace) do
      {:ok, scope} -> {:ok, scope}
      :error -> {:error, :unknown_namespace}
    end
  end

  @doc """
  Per-namespace operation CEILING — independent of, and checked before,
  ownership or any grant. Applies regardless of which space a request
  targets: a namespace listed read-only here stays read-only even for
  its "personal" space, same as it would for "private" or "public".

  CAUTION — calendar is listed read-only below to match the example
  given when this table was designed, but lib/przma/vault/calendar.ex
  currently has its own write actions (creating/updating events). If
  calendar is meant to stay writable through that module, either this
  entry needs [:read, :write] or calendar.ex's writes need to go
  through a different namespace than "calendar" — confirm before
  deploying, this WILL break calendar.ex's writes as currently listed.
  """
  @allowed_operations_by_namespace %{
    "vault" => [:read, :write],
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