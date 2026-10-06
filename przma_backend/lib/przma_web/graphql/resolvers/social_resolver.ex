defmodule PRZMAWeb.Graphql.Resolvers.SocialResolver do
  @moduledoc "Contacts, follows and notifications. Logic lives in Przma.Social.* and Przma.Notify.*."

  import PRZMAWeb.Graphql.Resolvers.Helpers

  alias Przma.Chat.Threads
  alias Przma.Notify.{Notifications, Settings}
  alias Przma.Social.{Contacts, Directory, Follows}

  # contacts
  def contacts(args, res), do: run(res, fn me -> Contacts.list(me.did, args[:contact_type]) end)
  def contact(%{did: did}, res), do: run(res, fn me -> Contacts.get(me.did, did) end)
  def contact_types(_args, res), do: run(res, fn me -> Contacts.types(me.did) end)
  def lookup_user(%{nickname: nickname}, res), do: run(res, fn _me -> Directory.lookup_nickname(nickname) end)

  def add_contact(%{did: did} = args, res),
    do: run(res, fn me -> Contacts.add(me, did, contact_type: args[:contact_type]) end)

  def add_contact_from_follower(%{did: did}, res), do: run(res, fn me -> Contacts.add_from_follower(me, did) end)
  def remove_contact(%{did: did}, res), do: run(res, fn me -> Contacts.remove(me, did) end)

  def classify_contact(%{did: did, contact_type: type}, res),
    do: run(res, fn me -> Contacts.classify(me, did, type) end)

  def create_contact_type(%{name: name} = args, res),
    do: run(res, fn me -> Contacts.create_type(me, name, args[:description]) end)

  # follows
  def followers(_args, res), do: run(res, fn me -> Follows.followers(me.did) end)
  def following(_args, res), do: run(res, fn me -> Follows.following(me.did) end)
  def suggestions(_args, res), do: run(res, fn me -> Follows.suggestions(me.did) end)
  def follow_user(%{did: did}, res), do: run(res, fn me -> Follows.follow(me, did) end)
  def unfollow_user(%{did: did}, res), do: run(res, fn me -> Follows.unfollow(me, did) end)
  def dismiss_suggestion(%{did: did}, res), do: run(res, fn me -> Follows.dismiss_suggestion(me, did) end)

  # notifications
  def notifications(args, res) do
    opts = paging(args) ++ [category: args[:category], unread_only: args[:unread_only]]
    run(res, fn me -> Notifications.list(me.did, opts) end)
  end

  def mark_notifications_read(_args, res) do
    run(res, fn me ->
      case Notifications.mark_read(me.did) do
        {:error, :not_found} -> Threads.unread_total(me.did)
        {:ok, _thread} -> Threads.unread_total(me.did)
        err -> err
      end
    end)
  end

  def notification_settings(_args, res), do: run(res, fn me -> Settings.get(me.did) end)

  def update_notification_settings(%{input: input}, res),
    do: run(res, fn me -> Settings.update(me.did, input) end)
end
