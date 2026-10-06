defmodule Przma.Circle.Permissions do
  @moduledoc """
  Who may do what in a circle. Roles: owner, admin, member, restricted
  (muted: can read, cannot send), audience (joined after the circle was
  full: can read, cannot send). Same matrix as the previous backend.
  """

  @matrix %{
    "send_message" => ~w(owner admin member),
    "receive_message" => ~w(owner admin member restricted audience),
    "add_member" => ~w(owner admin),
    "remove_member" => ~w(owner admin),
    "delete_edit_others_messages" => ~w(owner admin),
    "edit_circle_settings" => ~w(owner),
    "delete_circle" => ~w(owner),
    "promote_demote_roles" => ~w(owner),
    "pin_message" => ~w(owner admin member),
    "leave_circle" => ~w(admin member restricted audience)
  }

  @assignable ~w(admin member restricted audience)

  def can?(action, role), do: role in Map.get(@matrix, action, [])

  @doc "Roles an owner may give to a member (ownership moves only through transfer)."
  def assignable?(role), do: role in @assignable

  def can_remove?("owner", target_role), do: target_role != "owner"
  def can_remove?("admin", target_role), do: target_role in ~w(member restricted audience)
  def can_remove?(_actor_role, _target_role), do: false

  @doc "Owner/admin can unpin anything; anyone else only their own pin."
  def can_unpin?(actor_role, actor_did, pinned_by_did),
    do: actor_role in ~w(owner admin) or actor_did == pinned_by_did
end
