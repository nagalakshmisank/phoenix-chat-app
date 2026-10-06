defmodule PRZMAWeb.Graphql.Resolvers.CircleResolver do
  @moduledoc "Circles, members, circle messages, pins. Logic lives in Przma.Circle.*."

  import PRZMAWeb.Graphql.Resolvers.Helpers

  alias Przma.Circle.{Circles, Members, Messages, Pins}

  # queries
  def my_circles(_args, res), do: run(res, fn me -> Circles.my_circles(me.did) end)
  def circle(%{circle_id: id}, res), do: run(res, fn me -> Circles.get_for(me.did, id) end)
  def members(%{circle_id: id}, res), do: run(res, fn me -> Members.list_for(me.did, id) end)
  def pending(%{circle_id: id}, res), do: run(res, fn me -> Members.pending(me.did, id) end)
  def messages(%{circle_id: id} = args, res), do: run(res, fn me -> Messages.list(me.did, id, paging(args)) end)
  def pins(%{circle_id: id}, res), do: run(res, fn me -> Pins.list(me.did, id) end)
  def discover(args, res), do: run(res, fn _me -> Circles.discover(args[:limit] || 50) end)

  # circle lifecycle
  def create(%{name: name} = args, res), do: run(res, fn me -> Circles.create(me, name, args) end)
  def update(%{circle_id: id} = args, res), do: run(res, fn me -> Circles.update(me, id, args) end)
  def delete(%{circle_id: id}, res), do: run(res, fn me -> Circles.delete(me, id) end)
  def follow(%{circle_id: id}, res), do: run(res, fn me -> Circles.follow(me, id) end)

  # membership
  def join(%{invite_code: code}, res), do: run(res, fn me -> Members.join(me, code) end)
  def leave(%{circle_id: id}, res), do: run(res, fn me -> Members.leave(me, id) end)
  def approve(%{circle_id: id, member_did: did}, res), do: run(res, fn me -> Members.approve(me, id, did) end)
  def deny(%{circle_id: id, member_did: did}, res), do: run(res, fn me -> Members.deny(me, id, did) end)
  def add(%{circle_id: id, member_did: did}, res), do: run(res, fn me -> Members.add(me, id, did) end)
  def remove(%{circle_id: id, member_did: did}, res), do: run(res, fn me -> Members.remove(me, id, did) end)
  def mute(%{circle_id: id, member_did: did}, res), do: run(res, fn me -> Members.mute(me, id, did) end)

  def update_role(%{circle_id: id, member_did: did, role: role}, res),
    do: run(res, fn me -> Members.update_role(me, id, did, role) end)

  def transfer(%{circle_id: id, new_owner_did: did}, res), do: run(res, fn me -> Members.transfer(me, id, did) end)

  # messages and pins
  def send_message(%{circle_id: id} = args, res), do: run(res, fn me -> Messages.send(me, id, args) end)

  def delete_message(%{circle_id: id, message_id: msg}, res),
    do: run(res, fn me -> Messages.delete(me, id, msg) end)

  def typing(%{circle_id: id}, res), do: run(res, fn me -> Messages.typing(me, id) end)
  def pin(%{circle_id: id, message_id: msg}, res), do: run(res, fn me -> Pins.pin(me, id, msg) end)
  def unpin(%{circle_id: id, message_id: msg}, res), do: run(res, fn me -> Pins.unpin(me, id, msg) end)
end
