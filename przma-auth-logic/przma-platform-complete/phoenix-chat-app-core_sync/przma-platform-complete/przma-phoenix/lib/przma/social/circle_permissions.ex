defmodule PRZMA.Social.CirclePermissions do
  @matrix %{
    "send_message"                => ~w(owner admin member),
    "receive_message"              => ~w(owner admin member restricted),
    "add_member"                   => ~w(owner admin),
    "remove_member"                => ~w(owner admin),
    "delete_edit_others_messages"  => ~w(owner admin),
    "edit_circle_settings"         => ~w(owner),
    "delete_circle"                => ~w(owner),
    "promote_demote_roles"         => ~w(owner),
    "leave_circle"                 => ~w(owner admin member restricted)
  }

  def can?(action, role), do: role in Map.get(@matrix, action, [])

  def can_remove?(actor_role, target_role) do
    case {actor_role, target_role} do
      {"owner", _} -> true
      {"admin", "member"} -> true
      {"admin", "restricted"} -> true
      _ -> false
    end
  end
end