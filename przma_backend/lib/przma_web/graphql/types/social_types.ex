defmodule PRZMAWeb.Graphql.Types.SocialTypes do
  @moduledoc "Contacts, follows and notifications."
  use Absinthe.Schema.Notation

  alias PRZMAWeb.Graphql.Resolvers.SocialResolver

  object :contact do
    field :contact_did, :string
    field :nickname, :string
    field :display_name, :string
    @desc "direct = added by DID, follow = added from my followers, circle = approved into my circle"
    field :source, :string
    field :contact_type, :string
    field :status, :string
    field :added_at, :integer
  end

  object :contact_type do
    field :name, :string
    field :description, :string
    field :is_system, :boolean
  end

  @desc "A user as other users can see them (shared directory)."
  object :account do
    field :did, :string do
      resolve fn account, _args, _res -> {:ok, account["account_did"]} end
    end

    field :nickname, :string
    field :display_name, :string
    field :avatar_cid, :string
  end

  object :follower do
    field :follower_did, :string
    field :follow_status, :string
    field :dismissed, :boolean
    field :followed_at, :integer
  end

  object :following do
    field :target_did, :string
    field :nickname, :string
    field :follow_status, :string
    field :followed_at, :integer
  end

  @desc "true = alert me, false = deliver silently. Items are stored and counted either way."
  object :notification_settings do
    field :message, :boolean
    field :circle_message, :boolean
    field :file, :boolean
    field :circle, :boolean
    field :follow, :boolean
  end

  input_object :notification_settings_input do
    field :message, :boolean
    field :circle_message, :boolean
    field :file, :boolean
    field :circle, :boolean
    field :follow, :boolean
  end

  object :social_queries do
    field :contacts, list_of(:contact) do
      arg :contact_type, :string
      resolve &SocialResolver.contacts/2
    end

    field :contact, :contact do
      arg :did, non_null(:string)
      resolve &SocialResolver.contact/2
    end

    @desc "System labels (friend, family, colleague, related_person, ai_contact) plus my own."
    field :contact_types, list_of(:contact_type) do
      resolve &SocialResolver.contact_types/2
    end

    @desc "Find a user by nickname (Keycloak username)."
    field :lookup_user, :account do
      arg :nickname, non_null(:string)
      resolve &SocialResolver.lookup_user/2
    end

    @desc "People who follow me."
    field :followers, list_of(:follower) do
      resolve &SocialResolver.followers/2
    end

    @desc "People I follow."
    field :following, list_of(:following) do
      resolve &SocialResolver.following/2
    end

    @desc "Followers I have not added as contacts (and not dismissed)."
    field :contact_suggestions, list_of(:follower) do
      resolve &SocialResolver.suggestions/2
    end

    @desc "Non-message notifications (follows, circle events), newest first. Message alerts are the unread counts in `threads`."
    field :notifications, list_of(:activity) do
      arg :category, :string
      arg :unread_only, :boolean
      arg :before, :string
      arg :limit, :integer
      resolve &SocialResolver.notifications/2
    end

    field :notification_settings, :notification_settings do
      resolve &SocialResolver.notification_settings/2
    end
  end

  object :social_mutations do
    @desc "Way 1: add a contact directly by DID."
    field :add_contact, :contact do
      arg :did, non_null(:string)
      arg :contact_type, :string
      resolve &SocialResolver.add_contact/2
    end

    @desc "Way 2: add one of my followers as a contact."
    field :add_contact_from_follower, :contact do
      arg :did, non_null(:string)
      resolve &SocialResolver.add_contact_from_follower/2
    end

    field :remove_contact, :contact do
      arg :did, non_null(:string)
      resolve &SocialResolver.remove_contact/2
    end

    field :classify_contact, :contact do
      arg :did, non_null(:string)
      arg :contact_type, non_null(:string)
      resolve &SocialResolver.classify_contact/2
    end

    field :create_contact_type, :contact_type do
      arg :name, non_null(:string)
      arg :description, :string
      resolve &SocialResolver.create_contact_type/2
    end

    field :follow_user, :following do
      arg :did, non_null(:string)
      resolve &SocialResolver.follow_user/2
    end

    field :unfollow_user, :following do
      arg :did, non_null(:string)
      resolve &SocialResolver.unfollow_user/2
    end

    @desc "Hide a follower from contactSuggestions."
    field :dismiss_suggestion, :follower do
      arg :did, non_null(:string)
      resolve &SocialResolver.dismiss_suggestion/2
    end

    @desc "Mark all notifications read. Returns the remaining total unread count."
    field :mark_notifications_read, :integer do
      resolve &SocialResolver.mark_notifications_read/2
    end

    field :update_notification_settings, :notification_settings do
      arg :input, non_null(:notification_settings_input)
      resolve &SocialResolver.update_notification_settings/2
    end
  end
end
