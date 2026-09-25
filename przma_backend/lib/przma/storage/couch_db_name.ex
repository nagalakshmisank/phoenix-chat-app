defmodule Przma.Storage.CouchDbName do
  @moduledoc """
  One CouchDB database per user (per DID).

  CouchDB database names must start with a lowercase letter and may only
  contain a-z 0-9 _ $ ( ) + - /. Two forms, and they can never collide:

    * readable — for the normal Keycloak case, did:przma:<lowercase a-z 0-9 _>
        did:przma:kc_user1        -> przma_did_przma_kc_user1
    * hex      — for anything else (dots, @, uppercase, other DID methods)
        did:przma:kc.user         -> przma_x6469643a70727a6d613a6b632e75736572

  Why not just "replace bad characters with _"? Because then kc.user and
  kc_user would share one database. The readable form only accepts
  usernames that need no replacement except ":" (which a username cannot
  contain), so it is one-to-one; the hex form is one-to-one by definition;
  and readable names start with "przma_d" while hex names start with
  "przma_x", so the two forms never overlap.
  """

  @prefix "przma_"
  @readable ~r/^did:przma:[a-z0-9_]+$/

  @spec from_did(String.t()) :: String.t()
  def from_did(did) when is_binary(did) do
    if Regex.match?(@readable, did) do
      @prefix <> String.replace(did, ":", "_")
    else
      @prefix <> "x" <> Base.encode16(did, case: :lower)
    end
  end
end
