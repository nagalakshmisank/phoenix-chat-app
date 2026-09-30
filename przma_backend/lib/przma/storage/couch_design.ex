defmodule Przma.Storage.CouchDesign do
  @moduledoc """
  The `_design/przma` document installed in every user database.

  Its validate_doc_update function is GENERATED from NamespacePolicy —
  it is never edited by hand. So namespace rules exist in exactly one
  place (namespace_policy.ex), and CouchDB enforces the same rules as a
  second layer behind PzdbConnector:

    * _id must be {namespace}:{space}:{table}[:{record}]
    * namespace must be one NamespacePolicy allows :write for
      (read-only namespaces such as "calendar" are rejected)
    * space must be private | public | personal | cas
    * the namespace/space/table fields must match the _id
    * did is required

  `policy_version` is a hash of the generated function. CouchVault
  compares it on every registration and re-pushes the design doc when
  NamespacePolicy has changed.
  """

  alias Przma.Storage.CouchDocId
  alias Przma.Vault.NamespacePolicy

  @design_id "_design/przma"

  @spec design_id() :: String.t()
  def design_id, do: @design_id

  @spec design_doc() :: map()
  def design_doc do
    js = validate_doc_update_js()

    %{
      "_id" => @design_id,
      "language" => "javascript",
      "policy_version" => policy_version(js),
      "validate_doc_update" => js
    }
  end

  @spec validate_doc_update_js() :: String.t()
  def validate_doc_update_js do
    namespaces = NamespacePolicy.namespaces_allowing(:write) |> Enum.sort() |> Jason.encode!()
    spaces = Jason.encode!(CouchDocId.all_spaces())

    """
    function (newDoc, oldDoc, userCtx, secObj) {
      if (newDoc._id.indexOf('_design/') === 0) { return; }
      if (newDoc._deleted) { return; }
      var NAMESPACES = #{namespaces};
      var SPACES = #{spaces};
      var p = newDoc._id.split(':');
      if (p.length < 3 || p.length > 4) {
        throw({forbidden: 'id must be namespace:space:table[:record]'});
      }
      if (NAMESPACES.indexOf(p[0]) === -1) {
        throw({forbidden: 'namespace not writable: ' + p[0]});
      }
      if (SPACES.indexOf(p[1]) === -1) {
        throw({forbidden: 'unknown space: ' + p[1]});
      }
      if (newDoc.namespace !== p[0] || newDoc.space !== p[1] || newDoc.table !== p[2]) {
        throw({forbidden: 'namespace/space/table fields must match _id'});
      }
      if (!newDoc.did) {
        throw({forbidden: 'did is required'});
      }
    }
    """
  end

  defp policy_version(js) do
    :crypto.hash(:sha256, js) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end
end
