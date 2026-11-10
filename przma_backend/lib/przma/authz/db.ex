defmodule Przma.Authz.Db do
  @moduledoc """
  Thin helpers over Przma.Authz.Repo raw SQL.

  All authz SQL is written by hand with the `przma_authz.` schema prefix
  (no Ecto schemas), so the table definitions in the migration are the
  single source of truth for column names.
  """

  alias Przma.Authz.Repo

  @doc "Runs a query and returns rows as maps with atom keys."
  @spec all(String.t(), list()) :: {:ok, [map()]} | {:error, term()}
  def all(sql, params \\ []) do
    case Repo.query(sql, params) do
      {:ok, %{columns: nil}} -> {:ok, []}
      {:ok, %{columns: cols, rows: rows}} -> {:ok, Enum.map(rows, &to_map(cols, &1))}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "First row or nil."
  @spec one(String.t(), list()) :: {:ok, map() | nil} | {:error, term()}
  def one(sql, params \\ []) do
    with {:ok, rows} <- all(sql, params), do: {:ok, List.first(rows)}
  end

  @doc "Raises on error — only inside Repo.transaction/1."
  def one!(sql, params \\ []) do
    case one(sql, params) do
      {:ok, row} -> row
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def all!(sql, params \\ []) do
    case all(sql, params) do
      {:ok, rows} -> rows
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Runs a statement, ignoring its result."
  @spec exec(String.t(), list()) :: :ok | {:error, term()}
  def exec(sql, params \\ []) do
    case all(sql, params) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "UUID text -> 16-byte binary for Postgrex uuid params (nil stays nil)."
  def uuid(nil), do: nil
  def uuid(<<_::128>> = bin), do: bin
  def uuid(text) when is_binary(text), do: Ecto.UUID.dump!(text)

  @doc "16-byte binary uuid -> text."
  def uuid_text(nil), do: nil
  def uuid_text(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  def uuid_text(text) when is_binary(text), do: text

  @doc "IP tuple or string -> Postgrex.INET (nil when unknown)."
  def inet(nil), do: nil
  def inet(%Postgrex.INET{} = ip), do: ip
  def inet(ip) when is_tuple(ip), do: %Postgrex.INET{address: ip}

  def inet(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> %Postgrex.INET{address: tuple}
      _ -> nil
    end
  end

  def inet(_), do: nil

  defp to_map(cols, row) do
    cols
    |> Enum.zip(row)
    |> Map.new(fn {c, v} -> {String.to_atom(c), v} end)
  end
end
