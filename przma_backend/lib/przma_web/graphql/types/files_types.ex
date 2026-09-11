defmodule PRZMAWeb.Graphql.Types.FilesTypes do
  use Absinthe.Schema.Notation

  object :file_metadata do
    field :id, :string
    field :name, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :content_cas, :string
  end

  object :file_upload_result do
    field :file_id, :string
  end
end