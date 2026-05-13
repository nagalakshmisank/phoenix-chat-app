# lib/przma/calendar/governance.ex
#
# Calendar-specific governance — maps circle roles to permitted actions.
# Single authoritative source for all calendar permission decisions.

defmodule PRZMA.Calendar.Governance do

  # Role hierarchy — higher index = lower authority
  @role_order ~w(steward guardian contributor participant observer guest)

  @doc "All roles in descending authority order"
  def roles, do: @role_order

  @doc "Returns true if role_a has at least the authority of role_b"
  def role_at_least?(role_a, role_b) do
    idx_a = Enum.find_index(@role_order, &(&1 == role_a)) || 999
    idx_b = Enum.find_index(@role_order, &(&1 == role_b)) || 999
    idx_a <= idx_b
  end

  # ── CONTENT PERMISSIONS ──────────────────────────────────────────────────────

  @doc "Can this role create events/tasks/content in a circle?"
  def can_create_content?(role),
    do: role_at_least?(role, "contributor")

  @doc "Can this role edit any content (not just their own)?"
  def can_edit_any?(role),
    do: role_at_least?(role, "guardian")

  @doc "Can this role edit their own content?"
  def can_edit_own?(role),
    do: role_at_least?(role, "participant")

  @doc "Can this role delete any content?"
  def can_delete_any?(role),
    do: role_at_least?(role, "guardian")

  @doc "Can this role delete their own content?"
  def can_delete_own?(role),
    do: role_at_least?(role, "participant")

  @doc "Can this role share content to the circle?"
  def can_share_to_circle?(role),
    do: role_at_least?(role, "contributor")

  @doc "Can this role publish circle content to Commons?"
  def can_publish_to_commons?(role),
    do: role_at_least?(role, "guardian")

  @doc "Can this role pin content in the circle?"
  def can_pin?(role),
    do: role_at_least?(role, "guardian")

  # ── RSVP / INTERACTION ───────────────────────────────────────────────────────

  @doc "Can this role RSVP to events?"
  def can_rsvp?(role),
    do: role_at_least?(role, "participant") or role == "guest"

  @doc "Can this role vote in polls?"
  def can_vote?(role),
    do: role_at_least?(role, "participant") or role == "guest"

  @doc "Can this role comment on content?"
  def can_comment?(role),
    do: role_at_least?(role, "participant") or role == "guest"

  # ── TASK PERMISSIONS ─────────────────────────────────────────────────────────

  @doc "Can this role create tasks in the circle?"
  def can_create_task?(role),
    do: role_at_least?(role, "contributor")

  @doc "Can this role assign tasks to circle members?"
  def can_assign_task?(role),
    do: role_at_least?(role, "contributor")

  @doc "Can this role update (progress, block) their own assigned task?"
  def can_update_own_task?(role),
    do: role_at_least?(role, "participant")

  @doc "Can this role close any task?"
  def can_close_any_task?(role),
    do: role_at_least?(role, "guardian")

  # ── POLL PERMISSIONS ─────────────────────────────────────────────────────────

  @doc "Can this role create scheduling polls?"
  def can_create_poll?(role),
    do: role_at_least?(role, "contributor")

  @doc "Can this role resolve (close) a poll?"
  def can_resolve_poll?(role),
    do: role_at_least?(role, "guardian")

  # ── MEMBER MANAGEMENT ────────────────────────────────────────────────────────

  @doc "Can this role invite new members?"
  def can_invite_members?(role),
    do: role_at_least?(role, "guardian")

  @doc "Can this role remove members?"
  def can_remove_members?(role),
    do: role_at_least?(role, "guardian")

  @doc "Can this role modify the circle charter / rules?"
  def can_modify_charter?(role),
    do: role == "steward"

  @doc "Can this role dissolve the circle?"
  def can_dissolve?(role),
    do: role == "steward"

  # ── COMPANION CONFIGURATION ───────────────────────────────────────────────────

  @doc "Can this role configure companion mode for the circle?"
  def can_configure_companion?(role),
    do: role_at_least?(role, "guardian")

  @doc "Can this role assign AI agents to the circle?"
  def can_assign_agent?(role),
    do: role_at_least?(role, "guardian")

  # ── UNIFIED PERMISSION CHECK ─────────────────────────────────────────────────

  @doc """
  Check a named permission for a role.
  Returns true/false. Raises on unknown action.
  """
  def permitted?(role, action) do
    case action do
      :create_content       -> can_create_content?(role)
      :edit_any             -> can_edit_any?(role)
      :edit_own             -> can_edit_own?(role)
      :delete_any           -> can_delete_any?(role)
      :delete_own           -> can_delete_own?(role)
      :share_to_circle      -> can_share_to_circle?(role)
      :publish_to_commons   -> can_publish_to_commons?(role)
      :pin                  -> can_pin?(role)
      :rsvp                 -> can_rsvp?(role)
      :vote                 -> can_vote?(role)
      :comment              -> can_comment?(role)
      :create_task          -> can_create_task?(role)
      :assign_task          -> can_assign_task?(role)
      :update_own_task      -> can_update_own_task?(role)
      :close_any_task       -> can_close_any_task?(role)
      :create_poll          -> can_create_poll?(role)
      :resolve_poll         -> can_resolve_poll?(role)
      :invite_members       -> can_invite_members?(role)
      :remove_members       -> can_remove_members?(role)
      :modify_charter       -> can_modify_charter?(role)
      :dissolve             -> can_dissolve?(role)
      :configure_companion  -> can_configure_companion?(role)
      :assign_agent         -> can_assign_agent?(role)
      unknown               -> raise "Unknown calendar action: #{unknown}"
    end
  end

  @doc """
  Assert permission — returns :ok or {:error, :permission_denied}.
  Use in context modules where you want to return an error tuple.
  """
  def assert_permitted(role, action) do
    if permitted?(role, action) do
      :ok
    else
      {:error, :permission_denied}
    end
  end
end
