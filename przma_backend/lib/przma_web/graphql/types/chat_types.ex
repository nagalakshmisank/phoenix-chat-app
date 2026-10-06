defmodule PRZMAWeb.Graphql.Types.ChatTypes do
  @moduledoc "Chat service: messages (inbox/outbox items) and the chat list."
  use Absinthe.Schema.Notation

  alias PRZMAWeb.Graphql.Resolvers.ChatResolver

  @desc """
  One inbox or outbox item: a direct message, a circle message, a file,
  or a notification. `id` sorts by time (newest = greatest).
  """
  object :activity do
    field :id, :string
    @desc "Conversation it belongs to: the other person's key, c_<circleId>, or sys"
    field :thread_key, :string
    @desc "in = received, out = sent by me"
    field :direction, :string
    @desc "Message, Follow, JoinRequest, JoinApproved, CircleAdded, CircleRemoved, RoleChanged, ..."
    field :activity_type, :string
    @desc "message | circle_message | file | circle | follow"
    field :category, :string
    field :actor_did, :string
    field :content, :string
    @desc "Ready-to-show sentence (notifications only)"
    field :text, :string
    @desc "Hash of the attached file (from uploadFile / uploadBlob)"
    field :object_cas, :string
    field :object_name, :string
    field :object_mime, :string
    field :circle_id, :string
    @desc "The user a notification is about (new follower, member who joined, ...)"
    field :subject_did, :string
    field :client_id, :string
    @desc "sent | delivered | undelivered | deleted"
    field :status, :string
    field :saved_file_id, :string
    @desc "Microseconds since epoch"
    field :sent_at, :integer
    field :read, :boolean
    @desc "Live pushes only: true when the chat is muted or the category is switched off"
    field :silent, :boolean
  end

  @desc "One row of the chat list."
  object :thread do
    field :thread_key, :string
    @desc "dm | circle | system"
    field :kind, :string
    field :peer_did, :string
    field :circle_id, :string
    field :title, :string
    field :unread_count, :integer
    field :last_msg_id, :string
    field :last_preview, :string
    field :last_actor_did, :string
    field :last_category, :string
    field :last_at, :integer
    field :last_read_id, :string
    field :muted, :boolean
    field :muted_until, :integer
  end

  object :message_status do
    field :id, :string
    field :thread_key, :string
    field :status, :string
  end

  object :saved_file do
    field :file_id, :string
    field :content_cas, :string
  end

  object :chat_queries do
    @desc "Chat list: every conversation with its last message and unread count, most recent first."
    field :threads, list_of(:thread) do
      resolve &ChatResolver.threads/2
    end

    @desc "Total unread across all conversations and notifications (the app badge)."
    field :unread_count, :integer do
      resolve &ChatResolver.unread_count/2
    end

    @desc "A direct conversation with one person: sent and received merged, newest first."
    field :conversation, list_of(:activity) do
      arg :with_did, non_null(:string)
      arg :before, :string
      arg :limit, :integer
      resolve &ChatResolver.conversation/2
    end

    @desc "Received items of one conversation, newest first."
    field :inbox, list_of(:activity) do
      arg :thread_key, non_null(:string)
      arg :before, :string
      arg :limit, :integer
      resolve &ChatResolver.inbox/2
    end

    @desc "Sent items of one conversation, newest first."
    field :outbox, list_of(:activity) do
      arg :thread_key, non_null(:string)
      arg :before, :string
      arg :limit, :integer
      resolve &ChatResolver.outbox/2
    end

    field :message, :activity do
      arg :thread_key, non_null(:string)
      arg :id, non_null(:string)
      resolve &ChatResolver.message/2
    end

    @desc "Short-lived download URL for the file attached to a message."
    field :message_blob_url, :blob_download_result do
      arg :thread_key, non_null(:string)
      arg :id, non_null(:string)
      arg :expires_in, :integer
      resolve &ChatResolver.blob_url/2
    end
  end

  object :chat_mutations do
    @desc "Send a direct message. Give content, or objectCas (+ objectName) to send a file, or both."
    field :send_message, :activity do
      arg :to_did, non_null(:string)
      arg :content, :string
      arg :object_cas, :string
      arg :object_name, :string
      arg :object_mime, :string
      arg :client_id, :string
      resolve &ChatResolver.send_message/2
    end

    @desc "Delete my copy of a direct message; forEveryone (sender only) also hides the recipient's copy."
    field :delete_message, :message_status do
      arg :thread_key, non_null(:string)
      arg :id, non_null(:string)
      arg :for_everyone, :boolean
      resolve &ChatResolver.delete_message/2
    end

    @desc "Copy the file attached to a received message into my own files."
    field :save_message_to_vault, :saved_file do
      arg :thread_key, non_null(:string)
      arg :id, non_null(:string)
      resolve &ChatResolver.save_to_vault/2
    end

    @desc "Open a conversation: unread count goes to 0."
    field :mark_thread_read, :thread do
      arg :thread_key, non_null(:string)
      resolve &ChatResolver.mark_thread_read/2
    end

    field :mark_all_read, :boolean do
      resolve &ChatResolver.mark_all_read/2
    end

    @desc "Mute a conversation for `minutes`, or until unmuted when minutes is omitted."
    field :mute_thread, :thread do
      arg :thread_key, non_null(:string)
      arg :minutes, :integer
      resolve &ChatResolver.mute_thread/2
    end

    field :unmute_thread, :thread do
      arg :thread_key, non_null(:string)
      resolve &ChatResolver.unmute_thread/2
    end
  end
end
