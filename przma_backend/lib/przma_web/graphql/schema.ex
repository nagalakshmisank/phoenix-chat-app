defmodule PRZMAWeb.Graphql.Schema do
  use Absinthe.Schema
  import_types Absinthe.Plug.Types
  import_types PRZMAWeb.Graphql.Types.ProfileTypes
  import_types PRZMAWeb.Graphql.Types.FilesTypes
  import_types PRZMAWeb.Graphql.Types.RegistrationTypes
  import_types PRZMAWeb.Graphql.Types.ChatTypes
  import_types PRZMAWeb.Graphql.Types.CircleTypes
  import_types PRZMAWeb.Graphql.Types.SocialTypes
  alias PRZMAWeb.Graphql.Resolvers.{ProfileResolver, FilesResolver, RegistrationResolver}

  # The chat / circle / social services return CouchDB documents, whose
  # keys are strings ("thread_key"), while Absinthe's default looks a field
  # up by atom (:thread_key). This makes the default lookup accept both, so
  # those types need no per-field resolver. Existing atom-keyed results
  # (profile, files) behave exactly as before.
  def middleware([{Absinthe.Middleware.MapGet, key}], _field, _object),
    do: [{{__MODULE__, :get_field}, key}]

  def middleware(middleware, _field, _object), do: middleware

  @doc false
  def get_field(%{source: source} = resolution, key) do
    value =
      case source do
        %{^key => value} -> value
        %{} -> Map.get(source, Atom.to_string(key))
        _ -> nil
      end

    %{resolution | state: :resolved, value: value}
  end

  query do
    import_fields :chat_queries
    import_fields :circle_queries
    import_fields :social_queries

    @desc "The caller's profile (vault namespace, private space)."
    field :profile, :profile do
      resolve &ProfileResolver.show/2
    end

    field :files, list_of(:file_metadata) do
      arg :space, :string
      arg :owner_did, :string
      resolve &FilesResolver.list/2
    end

    @desc "Postgres commons CAS check: \"ok: N rows\" or \"error: …\" (connection / table problems)."
    field :commons_cas_status, :string do
      resolve &FilesResolver.commons_cas_status/2
    end

    @desc "Old REST GET /sync/cas-meta equivalent."
    field :cas_meta, list_of(:cas_meta_row) do
      arg :owner_did, :string
      resolve &FilesResolver.list_cas_meta/2
    end

    @desc "Old REST GET /sync/blob/:hash equivalent — returns a presigned S3 URL, not inline bytes."
    field :blob_download_url, :blob_download_result do
      arg :hash, non_null(:string)
      arg :space, :string
      arg :owner_did, :string
      arg :expires_in, :integer
      resolve &FilesResolver.blob_download_url/2
    end
  end

  mutation do
    import_fields :chat_mutations
    import_fields :circle_mutations
    import_fields :social_mutations

    @desc """
    Call once right after Keycloak sign-up (safe to repeat). Creates the
    user's CouchDB database and the profile document vault:private:profile.
    """
    field :complete_registration, :registration_result do
      arg :nickname, :string
      resolve &RegistrationResolver.complete/2
    end

    field :create_profile, :profile do
      arg :nickname, :string
      arg :display_name, :string
      arg :bio, :string
      arg :avatar_cid, :string
      resolve &ProfileResolver.create/2
    end

    @desc "Field-level update — only the fields you send are changed."
    field :update_profile, :profile do
      arg :nickname, :string
      arg :display_name, :string
      arg :bio, :string
      arg :avatar_cid, :string
      resolve &ProfileResolver.update/2
    end

    field :upload_file, :file_upload_result do
      arg :file, non_null(:upload)
      arg :space, :string
      arg :owner_did, :string
      resolve &FilesResolver.upload/2
    end

    @desc "Old REST POST /sync/blob equivalent — content only, no index row."
    field :upload_blob, :blob_upload_result do
      arg :file, non_null(:upload)
      arg :space, :string
      arg :owner_did, :string
      resolve &FilesResolver.upload_blob/2
    end

    @desc "Old REST POST /sync/record equivalent — index row only, for a blob already uploaded via uploadBlob."
    field :sync_file_record, :file_sync_result do
      arg :input, non_null(:file_record_input)
      resolve &FilesResolver.sync_record/2
    end
  end

  subscription do
    @desc """
    Everything that lands in my inbox, live: direct messages, circle
    messages, files and notifications. `silent` is true when the chat is
    muted or the category is switched off. Websocket: /socket (see UserSocket).
    """
    field :notification_received, :activity do
      config fn _args, %{context: context} ->
        case context do
          %{did: did} when is_binary(did) -> {:ok, topic: "user:" <> did}
          _ -> {:error, "unauthorized"}
        end
      end

      resolve fn item, _args, _res -> {:ok, item} end
    end

    @desc "Live events of one circle. Only active members can subscribe."
    field :circle_event, :circle_event do
      arg :circle_id, non_null(:string)

      config fn %{circle_id: circle_id}, %{context: context} ->
        with %{did: did} when is_binary(did) <- context,
             {:ok, _ctx} <- Przma.Circle.Members.context(did, circle_id) do
          {:ok, topic: "circle:" <> circle_id}
        else
          _ -> {:error, "forbidden"}
        end
      end

      resolve fn event, _args, _res -> {:ok, event} end
    end
  end
end
