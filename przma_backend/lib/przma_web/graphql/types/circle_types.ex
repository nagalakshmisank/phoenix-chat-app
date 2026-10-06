defmodule PRZMAWeb.Graphql.Types.CircleTypes do
  @moduledoc "Circle service: circles, roster, circle messages, pins."
  use Absinthe.Schema.Notation

  alias PRZMAWeb.Graphql.Resolvers.CircleResolver

  object :circle do
    field :circle_id, :string
    field :owner_did, :string
    field :name, :string
    @desc "private | public"
    field :visibility, :string
    field :member_count, :integer
    field :audience_count, :integer
    field :follower_count, :integer
    field :invite_code, :string
    field :join_approval_required, :boolean
    field :max_members, :integer
    field :status, :string
    @desc "owner | admin | member | restricted | audience"
    field :my_role, :string
    @desc "active | pending"
    field :my_status, :string
  end

  object :circle_member do
    field :circle_id, :string
    field :member_did, :string
    field :role, :string
    field :status, :string
    field :join_method, :string
    field :invited_by, :string
    field :joined_at, :integer
  end

  object :circle_pin do
    field :circle_id, :string
    field :message_id, :string
    field :pinned_by, :string
    field :pinned_at, :integer
    field :status, :string
  end

  object :circle_join_result do
    field :circle_id, :string
    @desc "active = you are in; pending = waiting for approval"
    field :status, :string
    field :role, :string
  end

  object :circle_status do
    field :circle_id, :string
    field :member_did, :string
    field :status, :string
  end

  object :public_circle do
    field :circle_id, :string
    field :owner_did, :string
    field :name, :string
  end

  @desc "Live circle event: new_message, message_deleted, message_pinned, message_unpinned, member_joined, member_left, member_removed, member_muted, role_changed, join_requested, ownership_transferred, circle_updated, circle_deleted, new_follower, typing."
  object :circle_event do
    field :circle_id, :string
    field :event, :string
    field :actor_did, :string
    field :member_did, :string
    field :message_id, :string
    field :role, :string
    field :at, :integer
  end

  object :circle_queries do
    @desc "Circles I own or joined (myStatus pending = join request not approved yet)."
    field :my_circles, list_of(:circle) do
      resolve &CircleResolver.my_circles/2
    end

    field :circle, :circle do
      arg :circle_id, non_null(:string)
      resolve &CircleResolver.circle/2
    end

    field :circle_members, list_of(:circle_member) do
      arg :circle_id, non_null(:string)
      resolve &CircleResolver.members/2
    end

    @desc "Join requests waiting for approval (owner/admin)."
    field :pending_members, list_of(:circle_member) do
      arg :circle_id, non_null(:string)
      resolve &CircleResolver.pending/2
    end

    @desc "The circle's messages, newest first."
    field :circle_messages, list_of(:activity) do
      arg :circle_id, non_null(:string)
      arg :before, :string
      arg :limit, :integer
      resolve &CircleResolver.messages/2
    end

    field :circle_pins, list_of(:circle_pin) do
      arg :circle_id, non_null(:string)
      resolve &CircleResolver.pins/2
    end

    @desc "Public circles anyone can follow."
    field :discover_circles, list_of(:public_circle) do
      arg :limit, :integer
      resolve &CircleResolver.discover/2
    end
  end

  object :circle_mutations do
    field :create_circle, :circle do
      arg :name, non_null(:string)
      arg :visibility, :string
      arg :join_approval_required, :boolean
      arg :max_members, :integer
      resolve &CircleResolver.create/2
    end

    @desc "Owner only."
    field :update_circle, :circle do
      arg :circle_id, non_null(:string)
      arg :name, :string
      arg :visibility, :string
      arg :join_approval_required, :boolean
      arg :max_members, :integer
      resolve &CircleResolver.update/2
    end

    @desc "Owner only."
    field :delete_circle, :circle_status do
      arg :circle_id, non_null(:string)
      resolve &CircleResolver.delete/2
    end

    field :join_circle, :circle_join_result do
      arg :invite_code, non_null(:string)
      resolve &CircleResolver.join/2
    end

    field :leave_circle, :circle_status do
      arg :circle_id, non_null(:string)
      resolve &CircleResolver.leave/2
    end

    field :approve_member, :circle_member do
      arg :circle_id, non_null(:string)
      arg :member_did, non_null(:string)
      resolve &CircleResolver.approve/2
    end

    field :deny_member, :circle_status do
      arg :circle_id, non_null(:string)
      arg :member_did, non_null(:string)
      resolve &CircleResolver.deny/2
    end

    @desc "Add one of my contacts directly (owner/admin, no approval)."
    field :add_member, :circle_member do
      arg :circle_id, non_null(:string)
      arg :member_did, non_null(:string)
      resolve &CircleResolver.add/2
    end

    field :remove_member, :circle_status do
      arg :circle_id, non_null(:string)
      arg :member_did, non_null(:string)
      resolve &CircleResolver.remove/2
    end

    @desc "Sets the member's role to restricted (can read, cannot send)."
    field :mute_member, :circle_member do
      arg :circle_id, non_null(:string)
      arg :member_did, non_null(:string)
      resolve &CircleResolver.mute/2
    end

    @desc "Owner only. role: admin | member | restricted | audience"
    field :update_member_role, :circle_member do
      arg :circle_id, non_null(:string)
      arg :member_did, non_null(:string)
      arg :role, non_null(:string)
      resolve &CircleResolver.update_role/2
    end

    field :transfer_ownership, :circle do
      arg :circle_id, non_null(:string)
      arg :new_owner_did, non_null(:string)
      resolve &CircleResolver.transfer/2
    end

    field :send_circle_message, :activity do
      arg :circle_id, non_null(:string)
      arg :content, :string
      arg :object_cas, :string
      arg :object_name, :string
      arg :object_mime, :string
      arg :client_id, :string
      resolve &CircleResolver.send_message/2
    end

    @desc "Delete for everyone: the sender, or owner/admin for any message."
    field :delete_circle_message, :message_status do
      arg :circle_id, non_null(:string)
      arg :message_id, non_null(:string)
      resolve &CircleResolver.delete_message/2
    end

    field :pin_message, :circle_pin do
      arg :circle_id, non_null(:string)
      arg :message_id, non_null(:string)
      resolve &CircleResolver.pin/2
    end

    field :unpin_message, :circle_pin do
      arg :circle_id, non_null(:string)
      arg :message_id, non_null(:string)
      resolve &CircleResolver.unpin/2
    end

    @desc "Follow a public circle."
    field :follow_circle, :circle_status do
      arg :circle_id, non_null(:string)
      resolve &CircleResolver.follow/2
    end

    @desc "Tell the other members I am typing (live only, nothing stored)."
    field :circle_typing, :boolean do
      arg :circle_id, non_null(:string)
      resolve &CircleResolver.typing/2
    end
  end
end
