defmodule PRZMA.Social.CirclePermissions do
  @matrix %{
    "send_message"                => ~w(owner admin member),
    "receive_message"              => ~w(owner admin member restricted audience),
    "add_member"                   => ~w(owner admin),
    "remove_member"                => ~w(owner admin),
    "delete_edit_others_messages"  => ~w(owner admin),
    "edit_circle_settings"         => ~w(owner),
    "delete_circle"                => ~w(owner),
    "promote_demote_roles"         => ~w(owner),
    "pin_message"                  => ~w(owner admin member),
    "leave_circle"                 => ~w(admin member restricted audience)
  }

  def can?(action, role), do: role in Map.get(@matrix, action, [])

  def can_remove?(actor_role, target_role) do
    case {actor_role, target_role} do
      {"owner", _} -> true
      {"admin", "member"} -> true
      {"admin", "restricted"} -> true
      {"admin", "audience"} -> true
      _ -> false
    end
  end

  # owner/admin can unpin anything; a plain member can only unpin their own pin
  def can_unpin?(actor_role, actor_did, pinned_by_did) do
    actor_role in ~w(owner admin) or actor_did == pinned_by_did
  end
end